/* rip-off convolution from decaf and port it to MATLAB and gpuArrays */

#include "mex.h"
#include "gpu/mxGPUArray.h"
#include <cublas_v2.h>
#include <blas.h>
#include <iostream>

#include "bits/im2col.cpp"

enum {
  IN_DATA = 0, IN_FILTERS, IN_DER, IN_END
} ;

enum {
  OUT_RESULT = 0, OUT_RESULT2, OUT_END
} ;

void mexFunction(int nout, mxArray *out[],
                 int nin, mxArray const *in[])
{
  mxClassID dataClassID ;
  mxClassID filtersClassID ;
  mxClassID derClassID ;
  mxGPUArray const *dataGpu ;
  mxGPUArray const *filtersGpu ;
  mxGPUArray const *derGpu ;

  mxGPUArray *resultGpu ;
  mxGPUArray *dfiltersGpu ;
  mxGPUArray *tempGpu ;

  mxArray *resultArray ;
  mxArray *dfiltersArray ;
  mxArray *tempArray ;

  cublasStatus_t stat;
  cublasHandle_t handle;

  size_t height, width, depth, numImages ;
  size_t filterHeight, filterWidth, filterDepth, numFilters ;
  size_t derHeight, derWidth, derDepth, numDerImages ;
  mwSize dataNumDimensions ;
  mwSize filtersNumDimensions ;
  mwSize derNumDimensions ;
  mwSize const * dataDimensions ;
  mwSize const * filtersDimensions ;
  mwSize const * derDimensions ;
  mwSize resultDimensions [4] ;
  mwSize dfiltersDimensions [4] ;
  mwSize tempDimensions [3] ;

  bool gpuMode = false ;
  bool backMode = false ;
  int verbosiy = 1 ;

  /* -------------------------------------------------------------- */
  /*                                            Check the arguments */
  /* -------------------------------------------------------------- */

  /* Throw an error if the input is not a GPU array. */
  if (nin != 2 && nin != 3) {
    mexErrMsgTxt("The arguments are neither two or three.") ;
  }

  backMode = (nin == 3) ;
  gpuMode = mxIsGPUArray(in[IN_DATA]) ;

  if (gpuMode) {
    if (!mxIsGPUArray(in[IN_FILTERS])) {
      mexErrMsgTxt("DATA is a GPU array but FILTERS is not.") ;
    }
    mxInitGPU() ;
    stat = cublasCreate(&handle);
    if (stat != CUBLAS_STATUS_SUCCESS) {
      mexErrMsgTxt("Could not initialize cuBLAS.") ;
    }
    dataGpu = mxGPUCreateFromMxArray(in[IN_DATA]) ;
    dataClassID = mxGPUGetClassID(dataGpu) ;
    dataNumDimensions = mxGPUGetNumberOfDimensions(dataGpu) ;
    dataDimensions = mxGPUGetDimensions(dataGpu) ;
    filtersGpu = mxGPUCreateFromMxArray(in[IN_FILTERS]) ;
    filtersClassID = mxGPUGetClassID(filtersGpu) ;
    filtersNumDimensions = mxGPUGetNumberOfDimensions(filtersGpu) ;
    filtersDimensions = mxGPUGetDimensions(filtersGpu) ;
    if (backMode) {
      if (!mxIsGPUArray(in[IN_DER])) {
        mexErrMsgTxt("DATA is a GPU array but FILTERS is not.") ;
      }
      derGpu = mxGPUCreateFromMxArray(in[IN_DER]) ;
      derClassID = mxGPUGetClassID(derGpu) ;
      derNumDimensions = mxGPUGetNumberOfDimensions(derGpu) ;
      derDimensions = mxGPUGetDimensions(derGpu) ;
    }
  } else {
    if (mxIsGPUArray(in[IN_FILTERS])) {
      mexErrMsgTxt("DATA is a CPU array but FILTERS is not.") ;
    }
    dataClassID = mxGetClassID(in[IN_DATA]) ;
    dataNumDimensions = mxGetNumberOfDimensions(in[IN_DATA]) ;
    dataDimensions = mxGetDimensions(in[IN_DATA]) ;
    filtersClassID = mxGetClassID(in[IN_FILTERS]) ;
    filtersNumDimensions = mxGetNumberOfDimensions(in[IN_FILTERS]) ;
    filtersDimensions = mxGetDimensions(in[IN_FILTERS]) ;
    if (backMode) {
      derClassID = mxGetClassID(in[IN_DER]) ;
      derNumDimensions = mxGetNumberOfDimensions(in[IN_DER]) ;
      derDimensions = mxGetDimensions(in[IN_DER]) ;
    }
  }

  if (dataClassID != mxSINGLE_CLASS) {
    mexErrMsgTxt("DATA is not of class SINGLE.");
  }
  if (filtersClassID != mxSINGLE_CLASS) {
    mexErrMsgTxt("FILTERS is not of class SINGLE.");
  }
  if (backMode && (derClassID != mxSINGLE_CLASS)) {
    mexErrMsgTxt("DER is not of class SINGLE.");
  }

  height = dataDimensions[0] ;
  width = dataDimensions[1] ;
  switch (dataNumDimensions) {
    case 2 : depth = 1 ; numImages = 1 ; break ;
    case 3 : depth = dataDimensions[2] ; numImages = 1 ; break ;
    case 4 : depth = dataDimensions[2] ; numImages = dataDimensions[3] ; break ;
    default:  mexErrMsgTxt("DATA has neither two nor three dimensions.") ; break ;
  }

  filterHeight = filtersDimensions[0] ;
  filterWidth = filtersDimensions[1] ;
  switch (filtersNumDimensions) {
    case 2 : filterDepth = 1 ; numFilters = 1 ; break ;
    case 3 : filterDepth = filtersDimensions[2] ; numFilters = 1 ; break ;
    case 4 : filterDepth = filtersDimensions[2] ; numFilters = filtersDimensions[3] ; break ;
    default:  mexErrMsgTxt("FILTERS has neither two, three, nor four dimensions.") ; break ;
  }

  if (backMode) {
    derHeight = derDimensions[0] ;
    derWidth = derDimensions[1] ;
    switch (derNumDimensions) {
      case 2 : derDepth = 1 ; numDerImages = 1 ; break ;
      case 3 : derDepth = derDimensions[2] ; numDerImages = 1 ; break ;
      case 4 : derDepth = derDimensions[2] ; numDerImages = derDimensions[3] ; break ;
      default:  mexErrMsgTxt("DER has neither two, three, nor four dimensions.") ; break ;
    }
  }

  if (filterWidth != filterHeight) {
    mexErrMsgTxt("Non-square FILTERS not supported yet.") ;
  }

  if (!backMode) {
    resultDimensions[0] = height - filterHeight + 1 ;
    resultDimensions[1] = width - filterWidth + 1 ;
    resultDimensions[2] = numFilters ;
    resultDimensions[3] = numImages ;
  } else {
    resultDimensions[0] = height ;
    resultDimensions[1] = width ;
    resultDimensions[2] = numFilters ;
    resultDimensions[3] = numImages ;
    dfiltersDimensions[0] = filterHeight ;
    dfiltersDimensions[1] = filterWidth ;
    dfiltersDimensions[2] = filterDepth ;
    dfiltersDimensions[3] = numFilters ;
  }

  tempDimensions[0] = height - filterHeight + 1 ;
  tempDimensions[1] = width - filterWidth + 1 ;
  tempDimensions[2] = filterHeight*filterWidth*filterDepth ;

  if (verbosiy > 0) {
    double const MB = 1024.0*1024.0 ;
    mexPrintf("gconv: mode %s; %s\n", gpuMode?"gpu":"cpu", backMode?"backward":"forward") ;
    mexPrintf("gconv: data: %d x %d x %d x %d [%.1f MB]\n",
              height, width, depth, numImages,
              (double)(height*width*depth*numImages*4)/MB) ;
    mexPrintf("gconv: filters: %d x %d x %d x %d [%.1f MB]\n",
              filterHeight, filterWidth, filterDepth, numFilters,
              (double)(filterHeight*filterWidth*filterDepth*numFilters*4)/MB) ;
    mexPrintf("gconv: result: %d x %d x %d x %d [%.1f MB]\n",
              resultDimensions[0], resultDimensions[1], resultDimensions[2], resultDimensions[3],
              (double)(resultDimensions[0]*resultDimensions[1]*resultDimensions[2]*resultDimensions[3]*4)/MB) ;
    if (backMode) {
      mexPrintf("gconv: der: %d x %d x %d x %d [%.1f MB]\n",
                derHeight, derWidth, derDepth, numDerImages,
                (double)(derHeight*derWidth*derDepth*numDerImages*4)/MB) ;
      mexPrintf("gconv: dfilters: %d x %d x %d x %d [%.1f MB]\n",
                dfiltersDimensions[0], dfiltersDimensions[1], dfiltersDimensions[2], dfiltersDimensions[3],
                (double)(dfiltersDimensions[0]*dfiltersDimensions[1]*dfiltersDimensions[2]*dfiltersDimensions[3]*4)/MB) ;
    }
    mexPrintf("gconv: temp: %d x %d x %d [%.1f MB]\n",
              tempDimensions[0], tempDimensions[1], tempDimensions[2],
              (double)(tempDimensions[0]*tempDimensions[1]*tempDimensions[2]*4)/MB) ;
  }

  if (backMode) {
    if (derHeight != tempDimensions[0] ||
        derWidth != tempDimensions[1] ||
        derDepth != numFilters ||
        numDerImages != numImages)
    {
      mexErrMsgTxt("DER dimensions are incompatible with X and FILTERS.") ;
    }
  }

  if (depth != filterDepth) {
    mexErrMsgTxt("DATA and FILTERS dimensions do not match.") ;
  }

  if (height < filterHeight ||  width < filterWidth) {
    mexErrMsgTxt("FILTERS are larger than the DATA.") ;
  }

  if (filterHeight == 0 || filterWidth == 0 || filterDepth == 0) {
    mexErrMsgTxt("A dimension of FILTERS is void.") ;
  }

  /* -------------------------------------------------------------- */
  /*                                                    Do the work */
  /* -------------------------------------------------------------- */
  // im2col should be called im2row

  if (gpuMode) {
    tempGpu = mxGPUCreateGPUArray(3, tempDimensions,
                                  mxSINGLE_CLASS,
                                  mxREAL,
                                  MX_GPU_DO_NOT_INITIALIZE) ;
    if (!backMode || nout > 1) {
      resultGpu = mxGPUCreateGPUArray(4, resultDimensions,
                                      mxSINGLE_CLASS,
                                      mxREAL,
                                      MX_GPU_DO_NOT_INITIALIZE) ;
    }
    if (backMode) {
      /* note that this buffer must be initialized to zero */
      dfiltersGpu = mxGPUCreateGPUArray(4, dfiltersDimensions,
                                        mxSINGLE_CLASS,
                                        mxREAL,
                                        MX_GPU_INITIALIZE_VALUES) ;
    }
  } else {
    tempArray = mxCreateNumericArray(3, tempDimensions,
                                     mxSINGLE_CLASS,
                                     mxREAL) ;
    if (!backMode || nout > 1) {
      resultArray = mxCreateNumericArray(4, resultDimensions,
                                         mxSINGLE_CLASS,
                                         mxREAL) ;
    }
    if (backMode) {
      dfiltersArray = mxCreateNumericArray(4, dfiltersDimensions,
                                           mxSINGLE_CLASS,
                                           mxREAL);
    }
  }

  for (int image = 0 ; image < numImages ; ++image) {

#if 0
    for (int n = 0; n < NUM_; ++n) {
      // since we saved memory in the forward pass by not storing all col data,
      // we will need to recompute them.
      im2col_cpu(bottom_data + (*bottom)[0]->offset(n), CHANNELS_, HEIGHT_,
                 WIDTH_, KSIZE_, STRIDE_, col_data);
      // gradient w.r.t. weight. Note that we will accumulate diffs.
      for (int g = 0; g < GROUP_; ++g) {
        caffe_cpu_gemm<Dtype>(CblasNoTrans, CblasTrans, M_, K_, N_,
                              (Dtype)1., top_diff + top[0]->offset(n) + top_offset * g,
                              col_data + col_offset * g, (Dtype)1.,
                              weight_diff + weight_offset * g);
      }
      // gradient w.r.t. bottom data, if necessary
      if (propagate_down) {
        for (int g = 0; g < GROUP_; ++g) {
          caffe_cpu_gemm<Dtype>(CblasTrans, CblasNoTrans, K_, N_, M_,
                                (Dtype)1., weight + weight_offset * g,
                                top_diff + top[0]->offset(n) + top_offset * g,
                                (Dtype)0., col_diff + col_offset * g);
        }
        // col2im back to the data
        col2im_cpu(col_diff, CHANNELS_, HEIGHT_,
                   WIDTH_, KSIZE_, STRIDE_, bottom_diff + (*bottom)[0]->offset(n));
      }
    }
#endif
    if (backMode) {
      /* ---------------------------------------------------------- */
      /*                                              Backward mode */
      /* ---------------------------------------------------------- */
      {
        float alpha = 1 ;
        float beta = 1 ;
        char opA = 't' ;
        char opB = 'n' ;
        ptrdiff_t m = tempDimensions[2] ; /* = filter volume */
        ptrdiff_t n = numFilters ;
        ptrdiff_t k = tempDimensions[0]*tempDimensions[1] ;
        ptrdiff_t dataOffset = (width*height*depth) * image ;
        if (gpuMode) {
          im2col_gpu<float>((float const*)mxGPUGetDataReadOnly(dataGpu) + dataOffset,
                            depth, height, width,
                            filterHeight,
                            1, // stride,
                            (float *)mxGPUGetData(tempGpu)) ;
          cublasSgemm(handle,
                      (opA == 'n') ? CUBLAS_OP_N : CUBLAS_OP_T,
                      (opB == 'n') ? CUBLAS_OP_N : CUBLAS_OP_T,
                      (int)m, (int)n, (int)k,
                      &alpha,
                      (float const*)mxGPUGetDataReadOnly(tempGpu), (opA == 'n') ? (int)m : (int)k,
                      (float const*)mxGPUGetDataReadOnly(derGpu), (opB == 'n') ? (int)k : (int)n,
                      &beta,
                      (float*)mxGPUGetData(dfiltersGpu), (int)m) ;
        } else {
          im2col_cpu<float>((float const*)mxGetData(in[IN_DATA]) + dataOffset,
                            depth, height, width,
                            filterHeight,
                            1, // stride,
                            (float *)mxGetData(tempArray)) ;
          sgemm(&opA, &opB,
                &m, &n, &k,
                &alpha,
                (float*)mxGetData(tempArray), (opA == 'n') ? &m : &k,
                (float*)mxGetData(in[IN_DER]) + dataOffset,(opB == 'n') ? &k : &n,
                &beta,
                (float*)mxGetData(dfiltersArray), &m) ;
        }
      }
      if (nout > 1) {
        float alpha = 1 ;
        float beta = 0 ;
        char opA = 'n' ;
        char opB = 't' ;
        ptrdiff_t m = tempDimensions[0]*tempDimensions[1] ;
        ptrdiff_t n = tempDimensions[2] ;
        ptrdiff_t k = numFilters ;
        ptrdiff_t dataOffset = (tempDimensions[0]*tempDimensions[1]*numFilters) * image ;
        ptrdiff_t resultOffset = (resultDimensions[0]*resultDimensions[1]*resultDimensions[2]) * image ;
        if (gpuMode) {
          cublasSgemm(handle,
                      (opA == 'n') ? CUBLAS_OP_N : CUBLAS_OP_T,
                      (opB == 'n') ? CUBLAS_OP_N : CUBLAS_OP_T,
                      (int)m, (int)n, (int)k,
                      &alpha,
                      (float const*)mxGPUGetDataReadOnly(derGpu) + dataOffset, (opA == 'n') ? (int)m : (int)k,
                      (float const*)mxGPUGetDataReadOnly(filtersGpu), (opB == 'n') ? (int)k : (int)n,
                      &beta,
                      (float*)mxGPUGetData(tempGpu), (int)m) ;
          col2im_gpu<float>((float*)mxGPUGetData(tempGpu),
                            depth, height, width,
                            filterHeight,
                            1,
                            (float*)mxGPUGetData(resultGpu) + resultOffset) ;
        } else {
          // overwrite temp
          sgemm(&opA, &opB,
                &m, &n, &k,
                &alpha,
                (float*)mxGetData(in[IN_DER]) + dataOffset, (opA == 'n') ? &m : &k,
                (float*)mxGetData(in[IN_FILTERS]),(opB == 'n') ? &k : &n,
                &beta,
                (float*)mxGetData(tempArray), &m) ;
          col2im_cpu<float>((float*)mxGetData(tempArray),
                            depth, height, width,
                            filterHeight,
                            1,
                            (float*)mxGetData(resultArray) + resultOffset) ;
        }
      }
    } else {
      /* ---------------------------------------------------------- */
      /*                                               Forward mode */
      /* ---------------------------------------------------------- */
      float alpha = 1 ;
      float beta = 0 ;
      char opA = 'n' ;
      char opB = 'n' ;
      ptrdiff_t m = resultDimensions[0]*resultDimensions[1] ;
      ptrdiff_t n = numFilters ;
      ptrdiff_t k = filterHeight*filterWidth*filterDepth ;
      ptrdiff_t dataOffset = (width*height*depth) * image ;
      ptrdiff_t resultOffset = (resultDimensions[0]*resultDimensions[1]*resultDimensions[2]) * image ;

      if (gpuMode) {
        im2col_gpu<float>((float const*)mxGPUGetDataReadOnly(dataGpu) + dataOffset,
                          depth, height, width,
                          filterHeight,
                          1, // stride,
                          (float *)mxGPUGetData(tempGpu)) ;
        // op = N (not transposed), T (transposed)
        // C <- alpha op(A)op(B) + beta C
        // A is m x k, B is k x n and C is m x n.
        cublasSgemm(handle,
                    (opA == 'n') ? CUBLAS_OP_N : CUBLAS_OP_T,
                    (opB == 'n') ? CUBLAS_OP_N : CUBLAS_OP_T,
                    (int)m, (int)n, (int)k,
                    &alpha,
                    (float const*)mxGPUGetDataReadOnly(tempGpu), (opA == 'n') ? (int)m : (int)k,
                    (float const*)mxGPUGetDataReadOnly(filtersGpu), (opB == 'n') ? (int)k : (int)n,
                    &beta,
                    (float*)mxGPUGetData(resultGpu) + resultOffset, (int)m) ;

      } else {
        if (opA == 't') {
          im2row_cpu<float>((float const*)mxGetData(in[IN_DATA]) + dataOffset,
                            depth, height, width,
                            filterHeight,
                            1, // stride,
                            (float *)mxGetData(tempArray)) ;
        } else {
          im2col_cpu<float>((float const*)mxGetData(in[IN_DATA]) + dataOffset,
                            depth, height, width,
                            filterHeight,
                            1, // stride,
                            (float *)mxGetData(tempArray)) ;
        }
        sgemm(&opA, &opB,
              &m, &n, &k,
              &alpha,
              (float*)mxGetData(tempArray), (opA == 'n') ? &m : &k,
              (float*)mxGetData(in[IN_FILTERS]),(opB == 'n') ? &k : &n,
              &beta,
              (float*)mxGetData(resultArray) + resultOffset, &m) ;
      }
    }
  }

  /* -------------------------------------------------------------- */
  /*                                                        Cleanup */
  /* -------------------------------------------------------------- */
  if (gpuMode) {
    if (backMode) {
      out[OUT_RESULT] = mxGPUCreateMxArrayOnGPU(dfiltersGpu) ;
      if (nout > 1) {
        out[OUT_RESULT2] = mxGPUCreateMxArrayOnGPU(resultGpu) ;
      }
    } else {
      out[OUT_RESULT] = mxGPUCreateMxArrayOnGPU(resultGpu) ;
    }
    mxGPUDestroyGPUArray(dataGpu) ;
    mxGPUDestroyGPUArray(filtersGpu) ;
    if (!backMode || nout > 1) { mxGPUDestroyGPUArray(resultGpu) ; }
    if (backMode) { mxGPUDestroyGPUArray(dfiltersGpu) ; }
    mxGPUDestroyGPUArray(tempGpu) ;
    cublasDestroy(handle);
  } else {
    mxDestroyArray(tempArray);
    if (backMode) {
      out[OUT_RESULT] = dfiltersArray ;
      if (nout > 1) { out[OUT_RESULT2] = resultArray ; }
    } else {
      out[OUT_RESULT] = resultArray ;
    }
  }
}