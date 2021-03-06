// Copyright 2013 Yangqing Jia

#include <algorithm>
#include <cfloat>
#include "caffe/layer.hpp"
#include "caffe/vision_layers.hpp"
#include "caffe/util/math_functions.hpp"

using std::max;
using std::min;

namespace caffe {

template <typename Dtype>
__global__ void MaxPoolForward(const int nthreads, const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int ksize, const int stride, Dtype* top_data,  int* max_idx_) {
  int index = threadIdx.x + (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x;
  if (index < nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride;
    int hend = min(hstart + ksize, height);
    int wstart = pw * stride;
    int wend = min(wstart + ksize, width);
    Dtype maxval = -FLT_MAX;
    int maxidx = -1;
    bottom_data += (n * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        if (bottom_data[h * width + w] > maxval){
          maxval = bottom_data[h * width + w];
          maxidx = h * width + w;
        }
      }
    }
    top_data[index] = maxval;
    max_idx_[index] = maxidx;
  }  // (if index < nthreads)
}

template <typename Dtype>
__global__ void AvePoolForward(const int nthreads, const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int ksize, const int stride, Dtype* top_data) {
  int index = threadIdx.x + (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x;
  if (index < nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride;
    int hend = min(hstart + ksize, height);
    int wstart = pw * stride;
    int wend = min(wstart + ksize, width);
    Dtype aveval = 0;
    bottom_data += (n * channels + c) * height * width;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        aveval += bottom_data[h * width + w];
      }
    }
    top_data[index] = aveval / (hend - hstart) / (wend - wstart);
  }  // (if index < nthreads)
}

template <typename Dtype>
__global__ void StoPoolForwardTrain(const int nthreads,
    const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int ksize, const int stride, float* rand_idx, Dtype* top_data) {
  int index = threadIdx.x + (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x;
  if (index < nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride;
    int hend = min(hstart + ksize, height);
    int wstart = pw * stride;
    int wend = min(wstart + ksize, width);
    Dtype cumsum = 0.;
    bottom_data += (n * channels + c) * height * width;
    // First pass: get sum
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        cumsum += bottom_data[h * width + w];
      }
    }
    float thres = rand_idx[index] * cumsum;
    // Second pass: get value, and set index.
    cumsum = 0;
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        cumsum += bottom_data[h * width + w];
        if (cumsum >= thres) {
          rand_idx[index] = ((n * channels + c) * height + h) * width + w;
          top_data[index] = bottom_data[h * width + w];
          return;
        }
      }
    }
  }  // (if index < nthreads)
}


template <typename Dtype>
__global__ void StoPoolForwardTest(const int nthreads,
    const Dtype* bottom_data,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int ksize, const int stride, Dtype* top_data) {
  int index = threadIdx.x + (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x;
  if (index < nthreads) {
    int pw = index % pooled_width;
    int ph = (index / pooled_width) % pooled_height;
    int c = (index / pooled_width / pooled_height) % channels;
    int n = index / pooled_width / pooled_height / channels;
    int hstart = ph * stride;
    int hend = min(hstart + ksize, height);
    int wstart = pw * stride;
    int wend = min(wstart + ksize, width);
    // We set cumsum to be 0 to avoid divide-by-zero problems
    Dtype cumsum = FLT_MIN;
    Dtype cumvalues = 0.;
    bottom_data += (n * channels + c) * height * width;
    // First pass: get sum
    for (int h = hstart; h < hend; ++h) {
      for (int w = wstart; w < wend; ++w) {
        cumsum += bottom_data[h * width + w];
        cumvalues += bottom_data[h * width + w] * bottom_data[h * width + w];
      }
    }
    top_data[index] = cumvalues / cumsum;
  }  // (if index < nthreads)
}


template <typename Dtype>
void PoolingLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      vector<Blob<Dtype>*>* top) {

  const Dtype* bottom_data = bottom[0]->gpu_data();
  const int* pooled_height = POOLED_HEIGHT_.cpu_data();
  const int* pooled_width = POOLED_WIDTH_.cpu_data();
  const int* ksize = KSIZE_.cpu_data();
  const int* stride = STRIDE_.cpu_data();

  for (int i = 0; i < top->size(); ++i){  
    Dtype* top_data = (*top)[i]->mutable_gpu_data();
    int count = (*top)[i]->count();
    switch (this->layer_param_.pool()) {
      case LayerParameter_PoolMethod_MAX:
        //LOG(INFO) << POOLED_HEIGHT_.cpu_data()[0] << " " << POOLED_WIDTH_.cpu_data()[0] << " "
        //  << KSIZE_.cpu_data()[0] << " " << STRIDE_.cpu_data()[0] << max_idx_[i].get()->cpu_data()[0];
        MaxPoolForward<Dtype><<<CAFFE_GET_BLOCKS2D(count), CAFFE_CUDA_NUM_THREADS>>>(
            count, bottom_data, bottom[0]->num(), CHANNELS_,
            HEIGHT_, WIDTH_, pooled_height[i], pooled_width[i], ksize[i], stride[i],
            top_data, max_idx_[i].get()->mutable_gpu_data());
        break;
      case LayerParameter_PoolMethod_AVE:
        AvePoolForward<Dtype><<<CAFFE_GET_BLOCKS2D(count), CAFFE_CUDA_NUM_THREADS>>>(
            count, bottom_data, bottom[0]->num(), CHANNELS_,
            HEIGHT_, WIDTH_, pooled_height[i], pooled_width[i], ksize[i], stride[i],
            top_data);
        break;
      case LayerParameter_PoolMethod_STOCHASTIC:
        
        if (Caffe::phase() == Caffe::TRAIN) {
          // We need to create the random index as well.
         
          CURAND_CHECK(curandGenerateUniform(Caffe::curand_generator(),
              rand_idx_[i].get()->mutable_gpu_data(), count));
          StoPoolForwardTrain<Dtype><<<CAFFE_GET_BLOCKS2D(count), CAFFE_CUDA_NUM_THREADS>>>(
              count, bottom_data, bottom[0]->num(), CHANNELS_,
              HEIGHT_, WIDTH_, pooled_height[i], pooled_width[i], ksize[i], stride[i],
              rand_idx_[i].get()->mutable_gpu_data(), top_data);
        } else {
          StoPoolForwardTest<Dtype><<<CAFFE_GET_BLOCKS2D(count), CAFFE_CUDA_NUM_THREADS>>>(
              count, bottom_data, bottom[0]->num(), CHANNELS_,
              HEIGHT_, WIDTH_, pooled_height[i], pooled_width[i], ksize[i], stride[i],
              top_data);
        }
        break;
      default:
        LOG(FATAL) << "Unknown pooling method.";
    }
    CUDA_POST_KERNEL_CHECK;
    }
  }

template <typename Dtype>
__global__ void MaxPoolBackward(const int nthreads, const Dtype* bottom_data,
    const Dtype* top_data, const Dtype* top_diff,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int ksize, const int stride, Dtype* bottom_diff,  int* max_idx_) {
  int index = threadIdx.x + (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x; 
  if (index < nthreads) {
    // find out the local index
    // find out the local offset
    int w = index % width;
    int h = (index / width) % height;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart = (h < ksize) ? 0 : (h - ksize) / stride + 1;
    int phend = min(h / stride + 1, pooled_height);
    int pwstart = (w < ksize) ? 0 : (w - ksize) / stride + 1;
    int pwend = min(w / stride + 1, pooled_width);
    Dtype gradient = 0;
    top_data += (n * channels + c) * pooled_height * pooled_width;
    top_diff += (n * channels + c) * pooled_height * pooled_width;
    max_idx_ += (n * channels + c) * pooled_height * pooled_width;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        if ((int)max_idx_[ph * pooled_width + pw] == h * width + w){
          gradient += top_diff[ph * pooled_width + pw];  
        }
      }
    }
    bottom_diff[index] += gradient;
  }  // (if index < nthreads)
}


template <typename Dtype>
__global__ void AvePoolBackward(const int nthreads, const Dtype* top_diff,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int ksize, const int stride, Dtype* bottom_diff) {
  int index = threadIdx.x + (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x;
  if (index < nthreads) {
    // find out the local index
    // find out the local offset
    int w = index % width;
    int h = (index / width) % height;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart = (h < ksize) ? 0 : (h - ksize) / stride + 1;
    int phend = min(h / stride + 1, pooled_height);
    int pwstart = (w < ksize) ? 0 : (w - ksize) / stride + 1;
    int pwend = min(w / stride + 1, pooled_width);
    Dtype gradient = 0;
    top_diff += (n * channels + c) * pooled_height * pooled_width;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        // figure out the pooling size
        int poolsize = (min(ph * stride + ksize, height) - ph * stride) *
            (min(pw * stride + ksize, width) - pw * stride);
        gradient += top_diff[ph * pooled_width + pw] / poolsize;
      }
    }
    bottom_diff[index] += gradient;
  }  // (if index < nthreads)
}


template <typename Dtype>
__global__ void StoPoolBackward(const int nthreads,
    const float* rand_idx, const Dtype* top_diff,
    const int num, const int channels, const int height,
    const int width, const int pooled_height, const int pooled_width,
    const int ksize, const int stride, Dtype* bottom_diff) {
  int index = threadIdx.x + (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x;
  if (index < nthreads) {
    // find out the local index
    // find out the local offset
    int w = index % width;
    int h = (index / width) % height;
    int c = (index / width / height) % channels;
    int n = index / width / height / channels;
    int phstart = (h < ksize) ? 0 : (h - ksize) / stride + 1;
    int phend = min(h / stride + 1, pooled_height);
    int pwstart = (w < ksize) ? 0 : (w - ksize) / stride + 1;
    int pwend = min(w / stride + 1, pooled_width);
    Dtype gradient = 0;
    rand_idx += (n * channels + c) * pooled_height * pooled_width;
    top_diff += (n * channels + c) * pooled_height * pooled_width;
    for (int ph = phstart; ph < phend; ++ph) {
      for (int pw = pwstart; pw < pwend; ++pw) {
        gradient += top_diff[ph * pooled_width + pw] *
            (index == int(rand_idx[ph * pooled_width + pw]));
      }
    }
    bottom_diff[index] += gradient;
  }  // (if index < nthreads)
}


template <typename Dtype>
Dtype PoolingLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
      const bool propagate_down, vector<Blob<Dtype>*>* bottom) {
  if (!propagate_down) {
    return Dtype(0.);
  }
  Dtype* bottom_diff = (*bottom)[0]->mutable_gpu_diff();
  int count = (*bottom)[0]->count();
  const int* pooled_height = POOLED_HEIGHT_.cpu_data();
  const int* pooled_width = POOLED_WIDTH_.cpu_data();
  const int* ksize = KSIZE_.cpu_data();
  const int* stride = STRIDE_.cpu_data();
  cudaMemset(bottom_diff, 0, count * sizeof(Dtype));
  for (int i = 0; i < top.size(); ++i){
    const Dtype* top_diff = top[i]->gpu_diff();
    switch (this->layer_param_.pool()) {
      case LayerParameter_PoolMethod_MAX:
        MaxPoolBackward<Dtype><<<CAFFE_GET_BLOCKS2D(count), CAFFE_CUDA_NUM_THREADS>>>(
            count, (*bottom)[0]->gpu_data(), top[i]->gpu_data(), top_diff,
            top[i]->num(), CHANNELS_, HEIGHT_, WIDTH_, pooled_height[i],
            pooled_width[i], ksize[i], stride[i], bottom_diff, max_idx_[i].get()->mutable_gpu_data());
        break;
      case LayerParameter_PoolMethod_AVE:
        AvePoolBackward<Dtype><<<CAFFE_GET_BLOCKS2D(count), CAFFE_CUDA_NUM_THREADS>>>(
            count, top_diff, top[i]->num(), CHANNELS_,
            HEIGHT_, WIDTH_, pooled_height[i], pooled_width[i], ksize[i], stride[i],
            bottom_diff);
        break;
      case LayerParameter_PoolMethod_STOCHASTIC:
        StoPoolBackward<Dtype><<<CAFFE_GET_BLOCKS2D(count), CAFFE_CUDA_NUM_THREADS>>>(
            count, rand_idx_[i].get()->gpu_data(), top_diff,
            top[i]->num(), CHANNELS_, HEIGHT_, WIDTH_, pooled_height[i],
            pooled_width[i], ksize[i], stride[i], bottom_diff);
        break;
      default:
        LOG(FATAL) << "Unknown pooling method.";
    }
    CUDA_POST_KERNEL_CHECK;
  }
  return Dtype(0.);
}


INSTANTIATE_CLASS(PoolingLayer);


}  // namespace caffe
