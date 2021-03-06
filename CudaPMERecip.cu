#include <typeinfo>
#include <iostream>
#include <cassert>
#include <math.h>
#include "gpu_utils.h"
#include "cuda_utils.h"
#include "reduce.h"
#include "CudaPMERecip.h"
#ifdef USE_FBFFT
#include "fbfft/FBFFT.cuh"
#include "fbfft/FBFFTCommon.cuh"

#define fbfftCheck(stmt) do {           \
    facebook::cuda::fbfft::FBFFTParameters::ErrorCode err = stmt;           \
    if (err != facebook::cuda::fbfft::FBFFTParameters::Success) {           \
      printf("Error running %s in file %s, function %s\n", #stmt,__FILE__,__FUNCTION__); \
      if (err == facebook::cuda::fbfft::FBFFTParameters::UnsupportedSize) \
        printf("Error code: UnsupportedSize\n"); \
      if (err == facebook::cuda::fbfft::FBFFTParameters::UnsupportedDimension) \
        printf("Error code: UnsupportedDimension\n"); \
      exit(1);                \
    }                 \
  } while(0)

#endif

static const double pi = 3.14159265358979323846;

//
// CudaPMERecip class
//
// AT  = Accumulation Type
// CT  = Calculation Type (real)
// CT2 = Calculation Type (complex)
//
// (c) Antti-Pekka Hynninen, 2013, aphynninen@hotmail.com
//
// In real space:
// Each instance of CudaPMERecip is responsible for grid region (x0..x1) x (y0..y1) x (z0..z1)
// Note that usually x0=0, x1=nfftx-1
//

// The generic version can only be used for float at the moment
template <typename T>
__forceinline__ __device__ void write_grid(const float val, const int ind,
             T* data) {
  atomicAdd(&data[ind], (T)val);
}

// Template specialization for 64bit integer = "long long int"
template <>
__forceinline__ __device__ void write_grid <long long int> (const float val,
							    const int ind,
							    long long int* data) {
  unsigned long long int qintp = llitoulli(lliroundf(FORCE_SCALE*val));
  atomicAdd((unsigned long long int *)&data[ind], qintp);
}

// Template specialization for 32bit integer = "int"
template <>
__forceinline__ __device__ void write_grid <int> (const float val,
						  const int ind,
						  int* data) {
  unsigned int qintp = itoui(iroundf(FORCE_SCALE_I*val));
  atomicAdd((unsigned int *)&data[ind], qintp);
}

/*
//
// Temporary kernels that change the data layout
//
__global__ void change_gridp(const int ncoord, const gridp_t *gridp,
			     int *ixtbl, int *iytbl, int *iztbl, float *charge) {

  unsigned int pos = blockIdx.x*blockDim.x + threadIdx.x;
  if (pos < ncoord) {
    gridp_t gridpval = gridp[pos];
    int x = gridpval.x;
    int y = gridpval.y;
    int z = gridpval.z;
    float q = gridpval.q;
    
    ixtbl[pos] = x;
    iytbl[pos] = y;
    iztbl[pos] = z;
    charge[pos] = q;
  }

}
*/

/*
__global__ void change_theta(const int ncoord, const float3 *theta,
			     float4 *thetax, float4 *thetay, float4 *thetaz) {

  unsigned int pos = blockIdx.x*blockDim.x + threadIdx.x;
  if (pos < ncoord) {
  thetax[pos].x = theta[pos*4].x;
    thetax[pos].y = theta[pos*4+1].x;
    thetax[pos].z = theta[pos*4+2].x;
    thetax[pos].w = theta[pos*4+3].x;

    thetay[pos].x = theta[pos*4].y;
    thetay[pos].y = theta[pos*4+1].y;
    thetay[pos].z = theta[pos*4+2].y;
    thetay[pos].w = theta[pos*4+3].y;

    thetaz[pos].x = theta[pos*4].z;
    thetaz[pos].y = theta[pos*4+1].z;
    thetaz[pos].z = theta[pos*4+2].z;
    thetaz[pos].w = theta[pos*4+3].z;    
  }

}
*/

//
// Calculate theta and dtheta for general order bspline
//
template <typename T, typename T3, int order>
__forceinline__ __device__ void calc_theta_dtheta(T wx, T wy, T wz, T3 *theta, T3 *dtheta) {

  theta[order-1].x = ((T)0);
  theta[order-1].y = ((T)0);
  theta[order-1].z = ((T)0);
  theta[1].x = wx;
  theta[1].y = wy;
  theta[1].z = wz;
  theta[0].x = ((T)1) - wx;
  theta[0].y = ((T)1) - wy;
  theta[0].z = ((T)1) - wz;

#pragma unroll
  for (int k=3;k <= order-1;k++) {
    T div = ((T)1) / (T)(k-1);
    theta[k-1].x = div*wx*theta[k-2].x;
    theta[k-1].y = div*wy*theta[k-2].y;
    theta[k-1].z = div*wz*theta[k-2].z;
#pragma unroll
    for (int j=1;j <= k-2;j++) {
      theta[k-j-1].x = div*((wx + j)*theta[k-j-2].x + (k-j-wx)*theta[k-j-1].x);
      theta[k-j-1].y = div*((wy + j)*theta[k-j-2].y + (k-j-wy)*theta[k-j-1].y);
      theta[k-j-1].z = div*((wz + j)*theta[k-j-2].z + (k-j-wz)*theta[k-j-1].z);
    }
    theta[0].x = div*(((T)1) - wx)*theta[0].x;
    theta[0].y = div*(((T)1) - wy)*theta[0].y;
    theta[0].z = div*(((T)1) - wz)*theta[0].z;
  }

  //--- perform standard b-spline differentiation
  dtheta[0].x = -theta[0].x;
  dtheta[0].y = -theta[0].y;
  dtheta[0].z = -theta[0].z;
#pragma unroll
  for (int j=2;j <= order;j++) {
    dtheta[j-1].x = theta[j-2].x - theta[j-1].x;
    dtheta[j-1].y = theta[j-2].y - theta[j-1].y;
    dtheta[j-1].z = theta[j-2].z - theta[j-1].z;
  }
	    
  //--- one more recursion
  T div = ((T)1) / (T)(order-1);
  theta[order-1].x = div*wx*theta[order-2].x;
  theta[order-1].y = div*wy*theta[order-2].y;
  theta[order-1].z = div*wz*theta[order-2].z;
#pragma unroll
  for (int j=1;j <= order-2;j++) {
    theta[order-j-1].x = div*((wx + j)*theta[order-j-2].x + (order-j-wx)*theta[order-j-1].x);
    theta[order-j-1].y = div*((wy + j)*theta[order-j-2].y + (order-j-wy)*theta[order-j-1].y);
    theta[order-j-1].z = div*((wz + j)*theta[order-j-2].z + (order-j-wz)*theta[order-j-1].z);
  }
    
  theta[0].x = div*(((T)1) - wx)*theta[0].x;
  theta[0].y = div*(((T)1) - wy)*theta[0].y;
  theta[0].z = div*(((T)1) - wz)*theta[0].z;
}

//
// General version for any order
//
template <typename T, int order>
__forceinline__ __device__ void calc_one_theta(const T w, T *theta) {

  theta[order-1] = ((T)0);
  theta[1] = w;
  theta[0] = ((T)1) - w;

#pragma unroll
  for (int k=3;k <= order-1;k++) {
    T div = ((T)1) / (T)(k-1);
    theta[k-1] = div*w*theta[k-2];
#pragma unroll
    for (int j=1;j <= k-2;j++) {
      theta[k-j-1] = div*((w+j)*theta[k-j-2] + (k-j-w)*theta[k-j-1]);
    }
    theta[0] = div*(((T)1) - w)*theta[0];
  }
	    
  //--- one more recursion
  T div = ((T)1) / (T)(order-1);
  theta[order-1] = div*w*theta[order-2];
#pragma unroll
  for (int j=1;j <= order-2;j++) {
    theta[order-j-1] = div*((w+j)*theta[order-j-2] + (order-j-w)*theta[order-j-1]);
  }
    
  theta[0] = div*(((T)1) - w)*theta[0];
}

#ifdef USE_NEW_SPREAD
__global__ void
place_charges_ortho(const float4 *xyzq, const int ncoord,
  const float recip11, const float recip22, const float recip33,
  const int nfftx, const int nffty, const int nfftz,
  const int xsize, const int ysize,
  int* coordIndGrid, int* coordIndOverflow, unsigned int* numCoordIndOverflow) {

  const int i = threadIdx.x + blockIdx.x*blockDim.x;

  if (i < ncoord) {
    float4 xyzqi = xyzq[i];
    float x = xyzqi.x;
    float y = xyzqi.y;
    float z = xyzqi.z;
    float q = xyzqi.w;

    float w;

    w = x*recip11 + 2.0f;
    float frx = (float)(nfftx*(w - (floorf(w + 0.5f) - 0.5f)));
    w = y*recip22 + 2.0f;
    float fry = (float)(nffty*(w - (floorf(w + 0.5f) - 0.5f)));
    w = z*recip33 + 2.0f;
    float frz = (float)(nfftz*(w - (floorf(w + 0.5f) - 0.5f)));

    int frxi = (int)frx;
    int fryi = (int)fry;
    int frzi = (int)frz;

    // Get position on the grid
    int ind = frxi + xsize*(fryi + ysize*frzi);

    // Store i+1 if old value is 0
    int old = atomicCAS(&coordIndGrid[ind], 0, i+1);

    // If already occupied, store into overflow
    if (old != 0) {
      int p = atomicInc(numCoordIndOverflow, ncoord+1);
      coordIndOverflow[p] = i;
    }
  }

}

//
// threadIdx.x = x
// blockIdx.y = y
// blockIdx.z = z
//
template <typename AT, int order>
__global__ void
spread_charge_ortho(const float4* __restrict__ xyzq, const int ncoord,
          const float recip11, const float recip22, const float recip33,
          const int nfftx, const int nffty, const int nfftz,
          const int xsize, const int ysize,
          const int* coordIndGrid, AT* data) {

  __shared__ float sh_thetax[64*order];
  __shared__ float sh_thetay[64*order];
  __shared__ float sh_thetaz[64*order];

  // data element this thread is writing
  AT dataval = (AT)0;

  // Loop over y-z plane and compute bsplines
  for (int tz=0;tz < order;tz++) {
    int iz = blockIdx.z - tz;
    if (iz < 0) iz += nfftz;
    for (int ty=0;ty < order;ty++) {
      int iy = blockIdx.y - ty;
      if (iy < 0) iy += nffty;
      int ind = threadIdx.x + xsize*(iy + ysize*iz);
      int pos = (threadIdx.x < nfftx) ? coordIndGrid[ind] : 0;

      __syncthreads();

      if (pos == 0) {
#pragma unroll
        for (int i=0;i < order;i++) {
          sh_thetax[threadIdx.x*order + i] = 0.0f;
          sh_thetay[threadIdx.x*order + i] = 0.0f;
          sh_thetaz[threadIdx.x*order + i] = 0.0f;
        }
      } else {
        float4 xyzqi = xyzq[pos-1];
        float x = xyzqi.x;
        float y = xyzqi.y;
        float z = xyzqi.z;
        float q = xyzqi.w;

        float w;

        w = x*recip11 + 2.0f;
        float frx = (float)(nfftx*(w - (floorf(w + 0.5f) - 0.5f)));
        w = y*recip22 + 2.0f;
        float fry = (float)(nffty*(w - (floorf(w + 0.5f) - 0.5f)));
        w = z*recip33 + 2.0f;
        float frz = (float)(nfftz*(w - (floorf(w + 0.5f) - 0.5f)));

        int frxi = (int)frx;
        int fryi = (int)fry;
        int frzi = (int)frz;

        int tmp = frxi + xsize*(fryi + ysize*frzi);

        float wx = frx - (float)frxi;
        float wy = fry - (float)fryi;
        float wz = frz - (float)frzi;

        float theta[order];

        calc_one_theta<float, order>(wx, theta);
#pragma unroll
        for (int i=0;i < order;i++) sh_thetax[threadIdx.x*order + i] = q*theta[i];

        calc_one_theta<float, order>(wy, theta);
#pragma unroll
        for (int i=0;i < order;i++) sh_thetay[threadIdx.x*order + i] = theta[i];

        calc_one_theta<float, order>(wz, theta);
#pragma unroll
        for (int i=0;i < order;i++) sh_thetaz[threadIdx.x*order + i] = theta[i];
      }

      __syncthreads();

      // Loop over x line
      if (threadIdx.x < nfftx) {
        for (int tx=0;tx < order;tx++) {
          int ix = threadIdx.x - tx;
          if (ix < 0) ix += nfftx;
          dataval += roundCTtoAT<AT, float>(sh_thetax[ix*order + tx]*sh_thetay[ix*order + ty]*sh_thetaz[ix*order + tz]);
        }
      }

    }
  }

  // Write data to global memory
  if (threadIdx.x < nfftx)
    data[threadIdx.x + xsize*(blockIdx.y + ysize*blockIdx.z)] = dataval;

}

template <typename AT, int order>
__global__ void
spread_overflow_charge_ortho(const float4* __restrict__ xyzq, const int ncoord,
          const float recip11, const float recip22, const float recip33,
          const int nfftx, const int nffty, const int nfftz,
          const int xsize, const int ysize,
          const int* coordIndOverflow, const unsigned int* numCoordIndOverflow,
          AT* data) {

  // Shared memory use:
  // order = 4: 1920 bytes
  // order = 6: 2688 bytes
  // order = 8: 3456 bytes
  __shared__ int sh_ix[32];
  __shared__ int sh_iy[32];
  __shared__ int sh_iz[32];
  __shared__ float sh_thetax[order*32];
  __shared__ float sh_thetay[order*32];
  __shared__ float sh_thetaz[order*32];

  const int ncoordOverflow = *numCoordIndOverflow;

  // pos0 = beginning of position for this block
  int pos0 = blockIdx.x*blockDim.x;

  while (pos0 < ncoordOverflow) {

    // Process atoms pos to pos_end-1
    int pos = pos0 + threadIdx.x;
    int pos_end = min(pos0 + blockDim.x, ncoordOverflow);

    __syncthreads();

    if (pos < pos_end && threadIdx.y == 0) {

      int i = coordIndOverflow[pos];

      float4 xyzqi = xyzq[i];
      float x = xyzqi.x;
      float y = xyzqi.y;
      float z = xyzqi.z;
      float q = xyzqi.w;

      float w;

      w = x*recip11 + 2.0f;
      float frx = (float)(nfftx*(w - (floorf(w + 0.5f) - 0.5f)));
      w = y*recip22 + 2.0f;
      float fry = (float)(nffty*(w - (floorf(w + 0.5f) - 0.5f)));
      w = z*recip33 + 2.0f;
      float frz = (float)(nfftz*(w - (floorf(w + 0.5f) - 0.5f)));

      int frxi = (int)frx;
      int fryi = (int)fry;
      int frzi = (int)frz;

      sh_ix[threadIdx.x] = frxi;
      sh_iy[threadIdx.x] = fryi;
      sh_iz[threadIdx.x] = frzi;

      float wx = frx - (float)frxi;
      float wy = fry - (float)fryi;
      float wz = frz - (float)frzi;

      float theta[order];

      calc_one_theta<float, order>(wx, theta);
#pragma unroll
      for (int i=0;i < order;i++) sh_thetax[threadIdx.x*order + i] = q*theta[i];

      calc_one_theta<float, order>(wy, theta);
#pragma unroll
      for (int i=0;i < order;i++) sh_thetay[threadIdx.x*order + i] = theta[i];

      calc_one_theta<float, order>(wz, theta);
#pragma unroll
      for (int i=0;i < order;i++) sh_thetaz[threadIdx.x*order + i] = theta[i];

    }

    __syncthreads();

    // Grid point location, values of (ix0, iy0, iz0) are in range 0..order-1
    // NOTE: Only tid=0...order*order*order-1 do any computation
    const int order3 = ((order*order*order-1)/warpSize + 1)*warpSize;
    const int tid = (threadIdx.x + threadIdx.y*blockDim.x) % order3;   // 0...order3-1
    const int x0 = tid % order;
    const int y0 = (tid / order) % order;
    const int z0 = tid / (order*order);

    // Loop over atoms pos..pos_end-1
    int iadd = blockDim.x*blockDim.y/order3;
    int i = (threadIdx.x + threadIdx.y*blockDim.x)/order3;
    int iend = pos_end - pos0;
    for (;i < iend;i += iadd) {
      int x = sh_ix[i] + x0;
      int y = sh_iy[i] + y0;
      int z = sh_iz[i] + z0;
        
      if (x >= nfftx) x -= nfftx;
      if (y >= nffty) y -= nffty;
      if (z >= nfftz) z -= nfftz;
        
      // Get position on the grid
      int ind = x + xsize*(y + ysize*(z));
        
      // Here we unroll the 6x6x6 loop with 216 threads.
      // NOTE: We use 7*32=224 threads to do this
      // Calculate interpolated charge value and store it to global memory
      if (tid < order*order*order)
        write_grid<AT>(sh_thetax[i*order+x0]*sh_thetay[i*order+y0]*sh_thetaz[i*order+z0], ind, data);
    }

    pos0 += blockDim.x*gridDim.x;
  }
}

#endif // USE_NEW_SPREAD

//
// Spreads the charge on the grid. Calculates theta and dtheta on the fly
// blockDim.x                   = Number of atoms each block loads
// blockDim.y*blockDim.x/order3 = Number of atoms we spread at once
//
template <typename AT, int order>
__global__ void
spread_charge_ortho(const float4 *xyzq, const int ncoord,
          const float recip11, const float recip22, const float recip33,
          const int nfftx, const int nffty, const int nfftz,
          const int xsize, const int ysize,
          AT* data) {

  // Shared memory use:
  // order = 4: 1920 bytes
  // order = 6: 2688 bytes
  // order = 8: 3456 bytes
  __shared__ int sh_ix[32];
  __shared__ int sh_iy[32];
  __shared__ int sh_iz[32];
  __shared__ float sh_thetax[order*32];
  __shared__ float sh_thetay[order*32];
  __shared__ float sh_thetaz[order*32];

  // Process atoms pos to pos_end-1
  const unsigned int pos = blockIdx.x*blockDim.x + threadIdx.x;
  const unsigned int pos_end = min((blockIdx.x+1)*blockDim.x, ncoord);

  if (pos < pos_end && threadIdx.y == 0) {

    float4 xyzqi = xyzq[pos];
    float x = xyzqi.x;
    float y = xyzqi.y;
    float z = xyzqi.z;
    float q = xyzqi.w;

    float w;

    w = x*recip11 + 2.0f;
    float frx = (float)(nfftx*(w - (floorf(w + 0.5f) - 0.5f)));
    w = y*recip22 + 2.0f;
    float fry = (float)(nffty*(w - (floorf(w + 0.5f) - 0.5f)));
    w = z*recip33 + 2.0f;
    float frz = (float)(nfftz*(w - (floorf(w + 0.5f) - 0.5f)));

    int frxi = (int)frx;
    int fryi = (int)fry;
    int frzi = (int)frz;

    sh_ix[threadIdx.x] = frxi;
    sh_iy[threadIdx.x] = fryi;
    sh_iz[threadIdx.x] = frzi;

    float wx = frx - (float)frxi;
    float wy = fry - (float)fryi;
    float wz = frz - (float)frzi;

    float theta[order];

    calc_one_theta<float, order>(wx, theta);
#pragma unroll
    for (int i=0;i < order;i++) sh_thetax[threadIdx.x*order + i] = q*theta[i];

    calc_one_theta<float, order>(wy, theta);
#pragma unroll
    for (int i=0;i < order;i++) sh_thetay[threadIdx.x*order + i] = theta[i];

    calc_one_theta<float, order>(wz, theta);
#pragma unroll
    for (int i=0;i < order;i++) sh_thetaz[threadIdx.x*order + i] = theta[i];

  }

  __syncthreads();

  // Grid point location, values of (ix0, iy0, iz0) are in range 0..order-1
  // NOTE: Only tid=0...order*order*order-1 do any computation
  const int order3 = ((order*order*order-1)/warpSize + 1)*warpSize;
  const int tid = (threadIdx.x + threadIdx.y*blockDim.x) % order3;   // 0...order3-1
  const int x0 = tid % order;
  const int y0 = (tid / order) % order;
  const int z0 = tid / (order*order);

  // Loop over atoms pos..pos_end-1
  int iadd = blockDim.x*blockDim.y/order3;
  int i = (threadIdx.x + threadIdx.y*blockDim.x)/order3;
  int iend = pos_end - blockIdx.x*blockDim.x;
  for (;i < iend;i += iadd) {
    int x = sh_ix[i] + x0;
    int y = sh_iy[i] + y0;
    int z = sh_iz[i] + z0;
      
    if (x >= nfftx) x -= nfftx;
    if (y >= nffty) y -= nffty;
    if (z >= nfftz) z -= nfftz;
      
    // Get position on the grid
    int ind = x + xsize*(y + ysize*(z));
      
    // Here we unroll the 6x6x6 loop with 216 threads.
    // NOTE: We use 7*32=224 threads to do this
    // Calculate interpolated charge value and store it to global memory
    if (tid < order*order*order)
      write_grid<AT>(sh_thetax[i*order+x0]*sh_thetay[i*order+y0]*sh_thetaz[i*order+z0], ind, data);
  }

}


// Local structure for scalar_sum -function for energy and virial reductions
struct RecipVirial_t {
  double energy;
  double virial[6];
};

//
// Performs scalar sum on data(nfft1, nfft2, nfft3)
// T = float or double
// T2 = float2 or double2
//
template <typename T, typename T2, bool calc_energy_virial>
__global__ void scalar_sum_ortho_kernel(const int nfft1, const int nfft2, const int nfft3,
					const int size1, const int size2, const int size3,
					const int nf1, const int nf2, const int nf3,
					const T recip11, const T recip22, const T recip33,
					const T* prefac1, const T* prefac2, const T* prefac3,
					const T fac, const T piv_inv,
					const bool global_base, T2* data,
					double* __restrict__ energy_recip,
					Virial_t* __restrict__ virial) {
  extern __shared__ T sh_prefac[];

  // Create pointers to shared memory
  T* sh_prefac1 = (T *)&sh_prefac[0];
  T* sh_prefac2 = (T *)&sh_prefac[nfft1];
  T* sh_prefac3 = (T *)&sh_prefac[nfft1 + nfft2];

  // Calculate start position (k1, k2, k3) for each thread
  unsigned int tid = blockIdx.x*blockDim.x + threadIdx.x;
  int k3 = tid/(size1*size2);
  tid -= k3*size1*size2;
  int k2 = tid/size1;
  int k1 = tid - k2*size1;

  // Calculate increments (k1_inc, k2_inc, k3_inc)
  int tot_inc = blockDim.x*gridDim.x;
  int k3_inc = tot_inc/(size1*size2);
  tot_inc -= k3_inc*size1*size2;
  int k2_inc = tot_inc/size1;
  int k1_inc = tot_inc - k2_inc*size1;

  // Set data[0] = 0 for the global (0,0,0)
  if (global_base && (blockIdx.x + threadIdx.x == 0)) {
    T2 zero;
    zero.x = (T)0;
    zero.y = (T)0;
    data[0] = zero;
    // Increment position
    k1 += k1_inc;
    if (k1 >= size1) {
      k1 -= size1;
      k2++;
    }
    k2 += k2_inc;
    if (k2 >= size2) {
      k2 -= size2;
      k3++;
    }
    k3 += k3_inc;
  }

  // Load prefac data into shared memory
  int pos = threadIdx.x;
  while (pos < nfft1) {
    sh_prefac1[pos] = prefac1[pos];
    pos += blockDim.x;
  }
  pos = threadIdx.x;
  while (pos < nfft2) {
    sh_prefac2[pos] = prefac2[pos];
    pos += blockDim.x;
  }
  pos = threadIdx.x;
  while (pos < nfft3) {
    sh_prefac3[pos] = prefac3[pos];
    pos += blockDim.x;
  }
  __syncthreads();

  double energy = 0.0;
  double virial0 = 0.0;
  double virial1 = 0.0;
  double virial2 = 0.0;
  double virial3 = 0.0;
  double virial4 = 0.0;
  double virial5 = 0.0;

  while (k3 < size3) {

    int pos = k1 + (k2 + k3*size2)*size1;
    T2 q = data[pos];

    int m1 = k1;
    int m2 = k2;
    int m3 = k3;
    if (k1 >= nf1) m1 -= nfft1;
    if (k2 >= nf2) m2 -= nfft2;
    if (k3 >= nf3) m3 -= nfft3;

    T mhat1 = recip11*m1;
    T mhat2 = recip22*m2;
    T mhat3 = recip33*m3;

    T msq = mhat1*mhat1 + mhat2*mhat2 + mhat3*mhat3;
    T msq_inv = (T)1.0/msq;

    // NOTE: check if it's faster to pre-calculate exp()
    T eterm = exp(-fac*msq)*piv_inv*sh_prefac1[k1]*sh_prefac2[k2]*sh_prefac3[k3]*msq_inv;

    if (calc_energy_virial) {
      T tmp1  = eterm*(q.x*q.x + q.y*q.y);
      T vterm  = ((T)2)*(fac + msq_inv);
      T tmp2   = tmp1*vterm;

      energy += (double)tmp1;
      virial0 += (double)(tmp1*(vterm*mhat1*mhat1 - ((T)1)));
      virial1 += (double)(tmp2*mhat1*mhat2);
      virial2 += (double)(tmp2*mhat1*mhat3);
      virial3 += (double)(tmp1*(vterm*mhat2*mhat2 - ((T)1)));
      virial4 += (double)(tmp2*mhat2*mhat3);
      virial5 += (double)(tmp1*(vterm*mhat3*mhat3 - ((T)1)));

      // The following is put into a separate if {} -block to avoid divergence within warp and
      // save registers
      if (k1 >= 1 && k1 < nfft1) {

	int k1s = nfft1 - (k1+1) + 1;
	int k2s = ((nfft2-(k2+1)+1) % nfft2);
	int k3s = ((nfft3-(k3+1)+1) % nfft3);

	int m1s = k1s;
	int m2s = k2s;
	int m3s = k3s;

	if (k1s >= nf1) m1s -= nfft1;
	if (k2s >= nf2) m2s -= nfft2;
	if (k3s >= nf3) m3s -= nfft3;

	T mhat1s = recip11*m1s;
	T mhat2s = recip22*m2s;
	T mhat3s = recip33*m3s;

	T msqs = mhat1s*mhat1s + mhat2s*mhat2s + mhat3s*mhat3s;
	T msqs_inv = ((T)1)/msqs;

	T eterms = exp(-fac*msqs)*piv_inv*sh_prefac1[k1s]*sh_prefac2[k2s]*sh_prefac3[k3s]*msqs_inv;

	T tmp1s  = eterms*(q.x*q.x + q.y*q.y);
	T vterms  = ((T)2)*(fac + msqs_inv);
	T tmp2s   = tmp1s*vterms;

	energy += (double)tmp1s;
	virial0 += (double)(tmp1s*(vterms*mhat1s*mhat1s - ((T)1)));
	virial1 += (double)(tmp2s*mhat1s*mhat2s);
	virial2 += (double)(tmp2s*mhat1s*mhat3s);
	virial3 += (double)(tmp1s*(vterms*mhat2s*mhat2s - ((T)1)));
	virial4 += (double)(tmp2s*mhat2s*mhat3s);
	virial5 += (double)(tmp1s*(vterms*mhat3s*mhat3s - ((T)1)));
      }
    }

    q.x *= eterm;
    q.y *= eterm;
    data[pos] = q;
    
    // Increment position
    k1 += k1_inc;
    if (k1 >= size1) {
      k1 -= size1;
      k2++;
    }
    k2 += k2_inc;
    if (k2 >= size2) {
      k2 -= size2;
      k3++;
    }
    k3 += k3_inc;
  }

  // Reduce energy and virial
  if (calc_energy_virial) {
#if __CUDA_ARCH__ < 300
    // Requires blockDim.x*sizeof(RecipVirial_t) amount of shared memory
    volatile RecipVirial_t* sh_ev = (RecipVirial_t *)sh_prefac;
    // NOTE: this __syncthreads() is needed because we're using a single shared memory buffer
    __syncthreads();
    sh_ev[threadIdx.x].energy  = energy;
    sh_ev[threadIdx.x].virial[0] = virial0;
    sh_ev[threadIdx.x].virial[1] = virial1;
    sh_ev[threadIdx.x].virial[2] = virial2;
    sh_ev[threadIdx.x].virial[3] = virial3;
    sh_ev[threadIdx.x].virial[4] = virial4;
    sh_ev[threadIdx.x].virial[5] = virial5;
    __syncthreads();
#endif
#if __CUDA_ARCH__ < 300
    for (int d=1;d < blockDim.x;d *= 2) {
      int t = threadIdx.x + d;
      double energy_val = (t < blockDim.x) ? sh_ev[t].energy : 0.0;
      double virial0_val = (t < blockDim.x) ? sh_ev[t].virial[0] : 0.0;
      double virial1_val = (t < blockDim.x) ? sh_ev[t].virial[1] : 0.0;
      double virial2_val = (t < blockDim.x) ? sh_ev[t].virial[2] : 0.0;
      double virial3_val = (t < blockDim.x) ? sh_ev[t].virial[3] : 0.0;
      double virial4_val = (t < blockDim.x) ? sh_ev[t].virial[4] : 0.0;
      double virial5_val = (t < blockDim.x) ? sh_ev[t].virial[5] : 0.0;
      __syncthreads();
      sh_ev[threadIdx.x].energy += energy_val;
      sh_ev[threadIdx.x].virial[0] += virial0_val;
      sh_ev[threadIdx.x].virial[1] += virial1_val;
      sh_ev[threadIdx.x].virial[2] += virial2_val;
      sh_ev[threadIdx.x].virial[3] += virial3_val;
      sh_ev[threadIdx.x].virial[4] += virial4_val;
      sh_ev[threadIdx.x].virial[5] += virial5_val;
      __syncthreads();
    }
#else
    const int tid = threadIdx.x & (warpsize-1);
    const int base = (threadIdx.x/warpsize);
    volatile RecipVirial_t* sh_ev = (RecipVirial_t *)sh_prefac;
    // Reduce within warps
    for (int d=warpsize/2;d >= 1;d /= 2) {
      energy += __hiloint2double(__shfl(__double2hiint(energy), tid+d),
				 __shfl(__double2loint(energy), tid+d));
      virial0 += __hiloint2double(__shfl(__double2hiint(virial0), tid+d),
				  __shfl(__double2loint(virial0), tid+d));
      virial1 += __hiloint2double(__shfl(__double2hiint(virial1), tid+d),
				  __shfl(__double2loint(virial1), tid+d));
      virial2 += __hiloint2double(__shfl(__double2hiint(virial2), tid+d),
				  __shfl(__double2loint(virial2), tid+d));
      virial3 += __hiloint2double(__shfl(__double2hiint(virial3), tid+d),
				  __shfl(__double2loint(virial3), tid+d));
      virial4 += __hiloint2double(__shfl(__double2hiint(virial4), tid+d),
				  __shfl(__double2loint(virial4), tid+d));
      virial5 += __hiloint2double(__shfl(__double2hiint(virial5), tid+d),
				  __shfl(__double2loint(virial5), tid+d));
    }
    // Reduce between warps
    // NOTE: this __syncthreads() is needed because we're using a single shared memory buffer
    __syncthreads();
    if (tid == 0) {
      sh_ev[base].energy = energy;
      sh_ev[base].virial[0] = virial0;
      sh_ev[base].virial[1] = virial1;
      sh_ev[base].virial[2] = virial2;
      sh_ev[base].virial[3] = virial3;
      sh_ev[base].virial[4] = virial4;
      sh_ev[base].virial[5] = virial5;
    }
    __syncthreads();
    if (base == 0) {
      energy = (tid < blockDim.x/warpsize) ? sh_ev[tid].energy : 0.0;
      virial0 = (tid < blockDim.x/warpsize) ? sh_ev[tid].virial[0] : 0.0;
      virial1 = (tid < blockDim.x/warpsize) ? sh_ev[tid].virial[1] : 0.0;
      virial2 = (tid < blockDim.x/warpsize) ? sh_ev[tid].virial[2] : 0.0;
      virial3 = (tid < blockDim.x/warpsize) ? sh_ev[tid].virial[3] : 0.0;
      virial4 = (tid < blockDim.x/warpsize) ? sh_ev[tid].virial[4] : 0.0;
      virial5 = (tid < blockDim.x/warpsize) ? sh_ev[tid].virial[5] : 0.0;
      for (int d=warpsize/2;d >= 1;d /= 2) {
	energy += __hiloint2double(__shfl(__double2hiint(energy), tid+d),
				   __shfl(__double2loint(energy), tid+d));
	virial0 += __hiloint2double(__shfl(__double2hiint(virial0), tid+d),
				    __shfl(__double2loint(virial0), tid+d));
	virial1 += __hiloint2double(__shfl(__double2hiint(virial1), tid+d),
				    __shfl(__double2loint(virial1), tid+d));
	virial2 += __hiloint2double(__shfl(__double2hiint(virial2), tid+d),
				    __shfl(__double2loint(virial2), tid+d));
	virial3 += __hiloint2double(__shfl(__double2hiint(virial3), tid+d),
				    __shfl(__double2loint(virial3), tid+d));
	virial4 += __hiloint2double(__shfl(__double2hiint(virial4), tid+d),
				    __shfl(__double2loint(virial4), tid+d));
	virial5 += __hiloint2double(__shfl(__double2hiint(virial5), tid+d),
				    __shfl(__double2loint(virial5), tid+d));
      }
    }
    
#endif

    if (threadIdx.x == 0) {
#if __CUDA_ARCH__ < 300
      energy = sh_ev[0].energy;
      virial0 = sh_ev[0].virial[0];
      virial1 = sh_ev[0].virial[1];
      virial2 = sh_ev[0].virial[2];
      virial3 = sh_ev[0].virial[3];
      virial4 = sh_ev[0].virial[4];
      virial5 = sh_ev[0].virial[5];
#endif
      atomicAdd(energy_recip, energy*half_ccelec);
      virial0 *= -half_ccelec;
      virial1 *= -half_ccelec;
      virial2 *= -half_ccelec;
      virial3 *= -half_ccelec;
      virial4 *= -half_ccelec;
      virial5 *= -half_ccelec;
      atomicAdd(&virial->virmat[0], virial0);
      atomicAdd(&virial->virmat[1], virial1);
      atomicAdd(&virial->virmat[2], virial2);
      atomicAdd(&virial->virmat[3], virial1);
      atomicAdd(&virial->virmat[4], virial3);
      atomicAdd(&virial->virmat[5], virial4);
      atomicAdd(&virial->virmat[6], virial2);
      atomicAdd(&virial->virmat[7], virial4);
      atomicAdd(&virial->virmat[8], virial5);
    }

  }

  /*
  // Set data[0] = 0 for the global (0,0,0)
  if (global_base && (blockIdx.x + threadIdx.x == 0)) {
    T2 zero;
    zero.x = (T)0;
    zero.y = (T)0;
    data[0] = zero;
  }
  */

}

#ifndef USE_TEXTURE_OBJECTS
texture<float, 1, cudaReadModeElementType> gridTexRef;
#endif

// Per atom data structure for the gather_force -kernels
template <typename T, int order>
struct gather_t {
  int ix;
  int iy;
  int iz;
  T charge;
  T thetax[order];
  T thetay[order];
  T thetaz[order];
  T dthetax[order];
  T dthetay[order];
  T dthetaz[order];
  float f1;
  float f2;
  float f3;
};

template <typename T>
__forceinline__ __device__ void write_force_atomic(const float fx,
						   const float fy,
						   const float fz,
						   const int ind,
						   const int stride,
						   const int stride2,
						   T* force) {
  // The generic version can not be used for anything
}

template <typename T>
__forceinline__ __device__ void write_force(const float fx,
					    const float fy,
					    const float fz,
					    const int ind,
					    const int stride,
					    const int stride2,
					    T* force) {
  // The generic version can not be used for anything
}

// Template specialization for 64bit integer = "long long int"
template <>
__forceinline__ __device__ void write_force_atomic <long long int> (const float fx,
								    const float fy,
								    const float fz,
								    const int ind,
								    const int stride,
								    const int stride2,
								    long long int* force) {
  unsigned long long int fx_ulli = llitoulli(lliroundf(FORCE_SCALE*fx));
  unsigned long long int fy_ulli = llitoulli(lliroundf(FORCE_SCALE*fy));
  unsigned long long int fz_ulli = llitoulli(lliroundf(FORCE_SCALE*fz));
  atomicAdd((unsigned long long int *)&force[ind          ], fx_ulli);
  atomicAdd((unsigned long long int *)&force[ind + stride ], fy_ulli);
  atomicAdd((unsigned long long int *)&force[ind + stride2], fz_ulli);
}

// Template specialization for 64bit integer = "long long int"
template <>
__forceinline__ __device__ void write_force <long long int> (const float fx,
							     const float fy,
							     const float fz,
							     const int ind,
							     const int stride,
							     const int stride2,
							     long long int* force) {
  unsigned long long int fx_ulli = llitoulli(lliroundf(FORCE_SCALE*fx));
  unsigned long long int fy_ulli = llitoulli(lliroundf(FORCE_SCALE*fy));
  unsigned long long int fz_ulli = llitoulli(lliroundf(FORCE_SCALE*fz));
  unsigned long long int *force_ulli = (unsigned long long int *)force;
  force_ulli[ind          ] += fx_ulli;
  force_ulli[ind + stride ] += fy_ulli;
  force_ulli[ind + stride2] += fz_ulli;
}


//-----------------------------------------------------------------------------------------
// Generic version can not be used
template <typename T> __forceinline__ __device__
void gather_force_store(const float fx, const float fy, const float fz,
			const int stride, const int pos,
			T* force) {
}

// Template specialization for "long long int"
template <> __forceinline__ __device__
void gather_force_store<long long int>(const float fx, const float fy, const float fz, 
				       const int stride, const int pos, 
				       long long int* force) {
  // Add into strided "long long int" array
  long long int fx_lli = lliroundf(fx*FORCE_SCALE);
  long long int fy_lli = lliroundf(fy*FORCE_SCALE);
  long long int fz_lli = lliroundf(fz*FORCE_SCALE);
  write_force<long long int>(fx_lli, fy_lli, fz_lli, pos, stride, force);
}

// Template specialization for "float"
template <> __forceinline__ __device__
void gather_force_store<float>(const float fx, const float fy, const float fz, 
			       const int stride, const int pos, 
			       float* force) {
  // Store into non-strided float XYZ array
  force[pos]          = fx;
  force[pos+stride]   = fy;
  force[pos+stride*2] = fz;
}

// Template specialization for "float3"
template <> __forceinline__ __device__
void gather_force_store<float3>(const float fx, const float fy, const float fz, 
				const int stride, const int pos, 
				float3* force) {
  // Store into non-strided "float3" array
  force[pos].x = fx;
  force[pos].y = fy;
  force[pos].z = fz;
}
//-----------------------------------------------------------------------------------------

//
// Gathers forces from the grid
// blockDim.x            = Number of atoms each block loads
// blockDim.x*blockDim.y = Total number of threads per block
//
template <typename CT, typename FT, int order>
__global__ void gather_force_ortho(const float4 *xyzq, const int ncoord,
              const int nfftx, const int nffty, const int nfftz,
              const int xsize, const int ysize, const int zsize,
              const float recip1, const float recip2, const float recip3,
              const float ccelec,
#ifdef USE_TEXTURE_OBJECTS
              const cudaTextureObject_t gridTexObj,
#endif
              const int stride,
              FT *force) {

  const int tid = threadIdx.x + threadIdx.y*blockDim.x; // 0...63

  // Shared memory
  __shared__ gather_t<CT, order> shmem[32];
#if __CUDA_ARCH__ < 300
  __shared__ float3 shred_buf[32*2];
  volatile float3 *shred = &shred_buf[(tid/8)*8];
#endif

  const int pos = blockIdx.x*blockDim.x + threadIdx.x;
  const int pos_end = min((blockIdx.x+1)*blockDim.x, ncoord);

  // Load atom data into shared memory
  if (pos < pos_end && threadIdx.y == 0) {

    float4 xyzqi = xyzq[pos];
    float x = xyzqi.x;
    float y = xyzqi.y;
    float z = xyzqi.z;
    float q = xyzqi.w;

    float w;

    w = x*recip1 + 2.0f;
    float frx = (float)(nfftx*(w - (floorf(w + 0.5f) - 0.5f)));

    w = y*recip2 + 2.0f;
    float fry = (float)(nffty*(w - (floorf(w + 0.5f) - 0.5f)));

    w = z*recip3 + 2.0f;
    float frz = (float)(nfftz*(w - (floorf(w + 0.5f) - 0.5f)));

    int frxi = (int)frx;
    int fryi = (int)fry;
    int frzi = (int)frz;

    shmem[threadIdx.x].ix = frxi;
    shmem[threadIdx.x].iy = fryi;
    shmem[threadIdx.x].iz = frzi;
    shmem[threadIdx.x].charge = q;

    float wx = frx - (float)frxi;
    float wy = fry - (float)fryi;
    float wz = frz - (float)frzi;

    float3 theta_tmp[order];
    float3 dtheta_tmp[order];
    calc_theta_dtheta<float, float3, order>(wx, wy, wz, theta_tmp, dtheta_tmp);
    
#pragma unroll
    for (int i=0;i < order;i++) shmem[threadIdx.x].thetax[i] = theta_tmp[i].x;

#pragma unroll
    for (int i=0;i < order;i++) shmem[threadIdx.x].thetay[i] = theta_tmp[i].y;

#pragma unroll
    for (int i=0;i < order;i++) shmem[threadIdx.x].thetaz[i] = theta_tmp[i].z;

#pragma unroll
    for (int i=0;i < order;i++) shmem[threadIdx.x].dthetax[i] = dtheta_tmp[i].x;

#pragma unroll
    for (int i=0;i < order;i++) shmem[threadIdx.x].dthetay[i] = dtheta_tmp[i].y;

#pragma unroll
    for (int i=0;i < order;i++) shmem[threadIdx.x].dthetaz[i] = dtheta_tmp[i].z;

  }
  __syncthreads();

  // We divide the order x order x order cube into 8 sub-cubes.
  // These sub-cubes are taken care by a single thread
  // The size of the sub-cubes is:
  // order=4 : 2x2x2
  // order=6 : 3x3x3
  // order=8 : 4x4x4
  const int nsc = (order == 4) ? 2 : ((order == 6) ? 3 : 4);
  // Calculate the starting index on the sub-cube for this thread
  // tid = 0...63
  const int t = (tid % 8);         // sub-cube index (0...7)
  // t = (tx0 + ty0*2 + tz0*4)/nsc
  // (tx0, ty0, tz0) gives the starting index of the 3x3x3 sub-cube
  const int tz0 = (t / 4)*nsc;
  const int ty0 = ((t / 2) % 2)*nsc;
  const int tx0 = (t % 2)*nsc;

  //
  // Calculate forces for 32 atoms. We have 32*2 = 64 threads
  // Loop is iterated 4 times:
  //                         (iterations)
  // Threads 0...7   = atoms 0, 8,  16, 24
  // Threads 8...15  = atoms 1, 9,  17, 25
  // Threads 16...31 = atoms 2, 10, 18, 26
  //                ...
  // Threads 56...63 = atoms 7, 15, 23, 31
  //

  int base = tid/8;
  const int base_end = pos_end - blockIdx.x*blockDim.x;
  while (base < base_end) {

    float f1 = 0.0f;
    float f2 = 0.0f;
    float f3 = 0.0f;
    int ix0 = shmem[base].ix;
    int iy0 = shmem[base].iy;
    int iz0 = shmem[base].iz;

    // Each thread calculates a nsc x nsc x nsc sub-cube
#pragma unroll
    for (int i=0;i < nsc*nsc*nsc;i++) {
      int tz = tz0 + (i/(nsc*nsc));
      int ty = ty0 + ((i/nsc) % nsc);
      int tx = tx0 + (i % nsc);

      int ix = ix0 + tx;
      int iy = iy0 + ty;
      int iz = iz0 + tz;
      if (ix >= nfftx) ix -= nfftx;
      if (iy >= nffty) iy -= nffty;
      if (iz >= nfftz) iz -= nfftz;
#ifdef USE_TEXTURE_OBJECTS
      float q0 = tex1Dfetch<float>(gridTexObj, ix + (iy + iz*ysize)*xsize);
#else
      float q0 = tex1Dfetch(gridTexRef, ix + (iy + iz*ysize)*xsize);
#endif
      float thx0 = shmem[base].thetax[tx];
      float thy0 = shmem[base].thetay[ty];
      float thz0 = shmem[base].thetaz[tz];
      float dthx0 = shmem[base].dthetax[tx];
      float dthy0 = shmem[base].dthetay[ty];
      float dthz0 = shmem[base].dthetaz[tz];
      f1 += dthx0 * thy0 * thz0 * q0;
      f2 += thx0 * dthy0 * thz0 * q0;
      f3 += thx0 * thy0 * dthz0 * q0;
    }

    //-------------------------

    // Reduce
#if __CUDA_ARCH__ >= 300
    const int i = threadIdx.x & 7;

    f1 += __shfl(f1, i+4, 8);
    f2 += __shfl(f2, i+4, 8);
    f3 += __shfl(f3, i+4, 8);

    f1 += __shfl(f1, i+2, 8);
    f2 += __shfl(f2, i+2, 8);
    f3 += __shfl(f3, i+2, 8);

    f1 += __shfl(f1, i+1, 8);
    f2 += __shfl(f2, i+1, 8);
    f3 += __shfl(f3, i+1, 8);

    if (i == 0) {
      shmem[base].f1 = f1;
      shmem[base].f2 = f2;
      shmem[base].f3 = f3;
    }

#else
    const int i = threadIdx.x & 7;
    shred[i].x = f1;
    shred[i].y = f2;
    shred[i].z = f3;

    if (i < 4) {
      shred[i].x += shred[i+4].x;
      shred[i].y += shred[i+4].y;
      shred[i].z += shred[i+4].z;
    }

    if (i < 2) {
      shred[i].x += shred[i+2].x;
      shred[i].y += shred[i+2].y;
      shred[i].z += shred[i+2].z;
    }

    if (i == 0) {
      shmem[base].f1 = shred[0].x + shred[1].x;
      shmem[base].f2 = shred[0].y + shred[1].y;
      shmem[base].f3 = shred[0].z + shred[1].z;
    }
#endif

    base += 8;
  }

  // Write forces
  __syncthreads();
  if (pos < pos_end && threadIdx.y == 0) {
    float f1 = shmem[threadIdx.x].f1;
    float f2 = shmem[threadIdx.x].f2;
    float f3 = shmem[threadIdx.x].f3;
    float q = shmem[threadIdx.x].charge*ccelec;
    float fx = q*recip1*f1*nfftx;
    float fy = q*recip2*f2*nffty;
    float fz = q*recip3*f3*nfftz;
    gather_force_store<FT>(fx, fy, fz, stride, pos, force);
  }

}


//
// Calculates self energy
// kappa_ccelec_sqrtpi = kappa*ccelec/sqrt(pi)
//
__global__ void calc_self_energy_kernel(const int ncoord, const float4* xyzq,
					const double kappa_ccelec_sqrtpi,
					double* __restrict__ energy_self) {
  // Shared memory
  // Required space: blockDim.x*sizeof(double)
  extern __shared__ double sh_q2[];

  int i = threadIdx.x + blockIdx.x*blockDim.x;
  float q = 0.0f;
  if (i < ncoord) q = xyzq[i].w;
  sh_q2[threadIdx.x] = q*q;
  __syncthreads();
  for(int d=1;d < blockDim.x;d *= 2) {
    int t = threadIdx.x + d;
    double q2_val = (t < blockDim.x) ? sh_q2[t] : 0.0;
    __syncthreads();
    sh_q2[threadIdx.x] += q2_val;
    __syncthreads();
  }
  if (threadIdx.x == 0) {
    atomicAdd(energy_self, -sh_q2[0]*kappa_ccelec_sqrtpi);
  }

}

//#####################################################################################
//#####################################################################################
//#####################################################################################

template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::setup_grid_texture(CT *data, const int data_len) {
  if (sizeof(CT) != 4) {
    std::cerr << "CudaPMERecip::setup_grid_texture, current implementation only tested for float-type textures" << std::endl;
    exit(1);
  }
#ifdef USE_TEXTURE_OBJECTS
  // Use texture objects
  cudaResourceDesc resDesc;
  memset(&resDesc, 0, sizeof(resDesc));
  resDesc.resType = cudaResourceTypeLinear;
  resDesc.res.linear.devPtr = data;
  resDesc.res.linear.desc.f = cudaChannelFormatKindFloat;
  resDesc.res.linear.desc.x = sizeof(CT)*8;
  resDesc.res.linear.sizeInBytes = data_len*sizeof(CT);
  cudaTextureDesc texDesc;
  memset(&texDesc, 0, sizeof(texDesc));
  texDesc.readMode = cudaReadModeElementType;
  cudaCheck(cudaCreateTextureObject(&gridTexObj, &resDesc, &texDesc, NULL));
#else
  gridTexRef.normalized = 0;
  gridTexRef.filterMode = cudaFilterModePoint;
  gridTexRef.addressMode[0] = cudaAddressModeClamp;
  gridTexRef.channelDesc.x = sizeof(CT)*8;
  gridTexRef.channelDesc.y = 0;
  gridTexRef.channelDesc.z = 0;
  gridTexRef.channelDesc.w = 0;
  gridTexRef.channelDesc.f = cudaChannelFormatKindFloat;
  cudaCheck(cudaBindTexture(NULL, gridTexRef, data, data_len*sizeof(CT)));
#endif
}

//
// Initializer
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::init(int x0, int x1, int y0, int y1, int z0, int z1, int order, 
				     bool y_land_locked, bool z_land_locked) {
  
  this->x0 = x0;
  this->x1 = x1;
  
  this->y0 = y0;
  this->y1 = y1;
  
  this->z0 = z0;
  this->z1 = z1;
  
  this->order = order;
  
  xlo = x0;
  xhi = x1;

  ylo = y0;
  yhi = y1;

  zlo = z0;
  zhi = z1;

  /*
  xhi += (order-1);

  if (y_land_locked) ylo -= (order-1);
  yhi += (order-1);
  
  if (z_land_locked) zlo -= (order-1);
  zhi += (order-1);
  */

  xsize = xhi - xlo + 1;
  ysize = yhi - ylo + 1;
  zsize = zhi - zlo + 1;

  data_size = (2*(xsize/2+1))*ysize*zsize;

  make_fft_plans();
  set_stream(stream);

  // data1 is used for accumulation, make sure it has enough space
  allocate<CT>(&data1, data_size*sizeof(AT)/sizeof(CT));
  allocate<CT>(&data2, data_size);

  if (multi_gpu) {
#ifdef USE_FBFFT
    std::cerr << "No Multi-gpu support in FBFFT" << std::endl;
    exit(1);
#else // !USE_FBFFT
#if CUDA_VERSION >= 6000
    cufftCheck(cufftXtMalloc(r2c_plan, &multi_data, CUFFT_XT_FORMAT_INPLACE));
    host_data = new CT2[xsize*ysize*zsize];
    host_tmp = new CT[2*(xsize/2+1)*ysize*zsize];
#else
    std::cerr << "No Multi-gpu FFT support in CUDA versions below 6.0" << std::endl;
    exit(1);
#endif
#endif // USE_FBFFT
  }

  data1_len = data_size*sizeof(AT)/sizeof(CT);
  data2_len = data_size;

  accum_grid  = new Matrix3d<AT>(xsize, ysize, zsize, xsize, ysize, zsize, (AT *)data1);
  charge_grid = new Matrix3d<CT>(xsize, ysize, zsize, xsize, ysize, zsize, (CT *)data2);

  if (fft_type == COLUMN) {
    xfft_grid   = new Matrix3d<CT2>(xsize/2+1, ysize, zsize, xsize/2+1, ysize, zsize, (CT2 *)data2);
    yfft_grid   = new Matrix3d<CT2>(ysize, zsize, xsize/2+1, ysize, zsize, xsize/2+1, (CT2 *)data1);
    zfft_grid   = new Matrix3d<CT2>(zsize, xsize/2+1, ysize, zsize, xsize/2+1, ysize, (CT2 *)data2);
    solved_grid = new Matrix3d<CT>(xsize, ysize, zsize, xsize, ysize, zsize, (CT *)data2);
  } else if (fft_type == SLAB) {
    xyfft_grid = new Matrix3d<CT2>(xsize/2+1, ysize, zsize, xsize/2+1, ysize, zsize, (CT2 *)data2);
    zfft_grid   = new Matrix3d<CT2>(zsize, xsize/2+1, ysize, zsize, xsize/2+1, ysize, (CT2 *)data1);
    solved_grid = new Matrix3d<CT>(xsize, ysize, zsize, xsize, ysize, zsize, (CT *)data2);
  } else if (fft_type == BOX) {
#ifdef USE_FBFFT
    std::cerr << "No 3D FFT support in FBFFT" << std::endl;
    exit(1);
#endif
    fft_grid = new Matrix3d<CT2>(xsize/2+1, ysize, zsize, xsize/2+1, ysize, zsize, (CT2 *)data2);
    solved_grid = new Matrix3d<CT>(xsize, ysize, zsize, xsize, ysize, zsize, (CT *)data2);
  }

  // Bind grid_texture to solved_grid->data (data2)
  setup_grid_texture(solved_grid->data, xsize*ysize*zsize);

}

//
// Class creator 
//
template <typename AT, typename CT, typename CT2>
CudaPMERecip<AT, CT, CT2>::CudaPMERecip(int nfftx, int nffty, int nfftz, int order,
					FFTtype fft_type, int nnode, int mynode,
					CudaEnergyVirial& energyVirial, const char* nameRecip, const char* nameSelf,
					cudaStream_t stream) :
  nfftx(nfftx), nffty(nffty), nfftz(nfftz), fft_type(fft_type),
  energyVirial(energyVirial), stream(stream) {

  assert(nnode >= 1);
  assert(mynode >= 0 && mynode < nnode);
  assert(sizeof(AT) >= sizeof(CT));
  assert(nameRecip != NULL);
  assert(nameSelf != NULL);

  // Insert energy terms
  energyVirial.insert(nameRecip);
  strRecip = nameRecip;
  energyVirial.insert(nameSelf);
  strSelf = nameSelf;
  
  int nnode_y, nnode_z;
  
  if (fft_type == COLUMN) {
    nnode_y = max(1,(int)ceil( sqrt( (double)(nnode*nffty) / (double)(nfftz) )));
    nnode_z = nnode/nnode_y;
    while (nnode_y*nnode_z != nnode) {
      nnode_y = nnode_y - 1;
      nnode_z = nnode/nnode_y;
    }
  } else if (fft_type == SLAB) {
    nnode_y = 1;
    nnode_z = nnode;
    assert(nfftz/nnode_z >= 1);
  } else if (fft_type == BOX) {
    assert(nnode == 1);
    nnode_y = 1;
    nnode_z = 1;
  } else {
    std::cerr<<"CudaPMERecip::fft_type invalid"<<std::endl;
    exit(1);
  }

  // We have nodes nnode_y * nnode_z. Get y and z index of this node:
  int inode_y = mynode % nnode_y;
  int inode_z = mynode/nnode_y;

  assert(nnode_y != 0);
  assert(nnode_z != 0);

  int x0 = 0;
  int x1 = nfftx-1;
      
  int y0 = inode_y*nffty/nnode_y;
  int y1 = (inode_y+1)*nffty/nnode_y - 1;

  int z0 = inode_z*nfftz/nnode_z;
  int z1 = (inode_z+1)*nfftz/nnode_z - 1;

  bool y_land_locked = (inode_y-1 >= 0) && (inode_y+1 < nnode_y);
  bool z_land_locked = (inode_z-1 >= 0) && (inode_z+1 < nnode_z);

  multi_gpu = false;

  assert((multi_gpu && fft_type==BOX) || !multi_gpu);

  init(x0, x1, y0, y1, z0, z1, order, y_land_locked, z_land_locked);

  allocate<CT>(&prefac_x, nfftx);
  allocate<CT>(&prefac_y, nffty);
  allocate<CT>(&prefac_z, nfftz);
  calc_prefac();

#ifdef USE_NEW_SPREAD
  coordIndOverflow_len = 0;
  coordIndOverflow = NULL;
  allocate<int>(&coordIndGrid, xsize*ysize*zsize + 1);
#endif

  //allocate<RecipEnergyVirial_t>(&d_energy_virial, 1);
  //allocate_host<RecipEnergyVirial_t>(&h_energy_virial, 1);

  //clear_energy_virial();
}

//
// Create FFT plans
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::make_fft_plans() {

  if (fft_type == COLUMN) {
    // Set the size of the local FFT transforms
    int nfftx_local = x1 - x0 + 1;
    int nffty_local = y1 - y0 + 1;
    int nfftz_local = z1 - z0 + 1;
    
#ifdef USE_FBFFT
    x_r2c_batchSize = nffty_local * nfftz_local;
    x_r2c_nfft = nfftx_local;

    y_c2c_batchSize = nfftz_local*(nfftx_local/2+1);
    y_c2c_nfft = nffty_local;

    z_c2c_batchSize = (nfftx_local/2+1)*nffty_local;
    z_c2c_nfft = nfftz_local;

    x_c2r_batchSize = nffty_local*nfftz_local;
    x_c2r_nfft = nfftx_local;
#else
    int batch;
    batch = nffty_local * nfftz_local;
    cufftCheck(cufftPlanMany(&x_r2c_plan, 1, &nfftx_local,
			     NULL, 0, 0,
			     NULL, 0, 0, 
			     CUFFT_R2C, batch));
    cufftCheck(cufftSetCompatibilityMode(x_r2c_plan, CUFFT_COMPATIBILITY_NATIVE));
    
    batch = nfftz_local*(nfftx_local/2+1);
    cufftCheck(cufftPlanMany(&y_c2c_plan, 1, &nffty_local,
			     NULL, 0, 0,
			     NULL, 0, 0, 
			     CUFFT_C2C, batch));
    cufftCheck(cufftSetCompatibilityMode(y_c2c_plan, CUFFT_COMPATIBILITY_NATIVE));

    batch = (nfftx_local/2+1)*nffty_local;
    cufftCheck(cufftPlanMany(&z_c2c_plan, 1, &nfftz_local,
			     NULL, 0, 0,
			     NULL, 0, 0, 
			     CUFFT_C2C, batch));
    cufftCheck(cufftSetCompatibilityMode(z_c2c_plan, CUFFT_COMPATIBILITY_NATIVE));

    batch = nffty_local*nfftz_local;
    cufftCheck(cufftPlanMany(&x_c2r_plan, 1, &nfftx_local,
			     NULL, 0, 0,
			     NULL, 0, 0, 
			     CUFFT_C2R, batch));
    cufftCheck(cufftSetCompatibilityMode(x_c2r_plan, CUFFT_COMPATIBILITY_NATIVE));
#endif
  } else if (fft_type == SLAB) {
    int nfftx_local = x1 - x0 + 1;
    int nffty_local = y1 - y0 + 1;
    int nfftz_local = z1 - z0 + 1;

    int n[2] = {nffty_local, nfftx_local};

#ifdef USE_FBFFT
    std::cerr << "make_fft_plans, SLAB not yet implemented for FBFFT" << std::endl;
    exit(1);
#else
    int batch;
    batch = nfftz_local;
    cufftCheck(cufftPlanMany(&xy_r2c_plan, 2, n,
			     NULL, 0, 0,
			     NULL, 0, 0, 
			     CUFFT_R2C, batch));
    cufftCheck(cufftSetCompatibilityMode(xy_r2c_plan, CUFFT_COMPATIBILITY_NATIVE));

    batch = (nfftx_local/2+1)*nffty_local;
    cufftCheck(cufftPlanMany(&z_c2c_plan, 1, &nfftz_local,
			     NULL, 0, 0,
			     NULL, 0, 0, 
			     CUFFT_C2C, batch));
    cufftCheck(cufftSetCompatibilityMode(z_c2c_plan, CUFFT_COMPATIBILITY_NATIVE));

    batch = nfftz_local;
    cufftCheck(cufftPlanMany(&xy_c2r_plan, 2, n,
			     NULL, 0, 0,
			     NULL, 0, 0, 
			     CUFFT_C2R, batch));
    cufftCheck(cufftSetCompatibilityMode(xy_c2r_plan, CUFFT_COMPATIBILITY_NATIVE));
#endif
  } else if (fft_type == BOX) {
#ifdef USE_FBFFT
    std::cerr << "make_fft_plans, BOX not supported for FBFFT" << std::endl;
    exit(1);
#else // !USE_FBFFT
    if (multi_gpu) {
#if CUDA_VERSION >= 6000
      cufftCheck(cufftCreate(&r2c_plan));
      cufftCheck(cufftCreate(&c2r_plan));
      int ngpu = 2;
      int gpu[2] = {2, 3};
      cufftCheck(cufftXtSetGPUs(r2c_plan, ngpu, gpu));
      cufftCheck(cufftXtSetGPUs(c2r_plan, ngpu, gpu));

      size_t worksize_r2c[2];
      size_t worksize_c2r[2];

      cufftCheck(cufftMakePlan3d(r2c_plan, nfftz, nffty, nfftx, CUFFT_C2C, worksize_r2c));
      cufftCheck(cufftMakePlan3d(c2r_plan, nfftz, nffty, nfftx, CUFFT_C2C, worksize_c2r));
#endif
    } else {
      cufftCheck(cufftPlan3d(&r2c_plan, nfftz, nffty, nfftx, CUFFT_R2C));
      cufftCheck(cufftSetCompatibilityMode(r2c_plan, CUFFT_COMPATIBILITY_NATIVE));

      cufftCheck(cufftPlan3d(&c2r_plan, nfftz, nffty, nfftx, CUFFT_C2R));
      cufftCheck(cufftSetCompatibilityMode(c2r_plan, CUFFT_COMPATIBILITY_NATIVE));
    }
#endif // USE_FBFFT
  }

}

//
// Set stream
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::set_stream(cudaStream_t stream) {

  this->stream = stream;

#ifndef USE_FBFFT
  if (fft_type == COLUMN) {
    cufftCheck(cufftSetStream(x_r2c_plan, stream));
    cufftCheck(cufftSetStream(y_c2c_plan, stream));
    cufftCheck(cufftSetStream(z_c2c_plan, stream));    
    cufftCheck(cufftSetStream(x_c2r_plan, stream));
  } else if (fft_type == SLAB) {
    cufftCheck(cufftSetStream(xy_r2c_plan, stream));
    cufftCheck(cufftSetStream(z_c2c_plan, stream));
    cufftCheck(cufftSetStream(xy_c2r_plan, stream));
  } else if (fft_type == BOX) {
    cufftCheck(cufftSetStream(r2c_plan, stream));
    cufftCheck(cufftSetStream(c2r_plan, stream));
  }
#endif

}


//
// Class destructor
//
template <typename AT, typename CT, typename CT2>
CudaPMERecip<AT, CT, CT2>::~CudaPMERecip() {

#ifdef USE_TEXTURE_OBJECTS
  cudaCheck(cudaDestroyTextureObject(gridTexObj));
#else
  // Unbind grid texture
  cudaCheck(cudaUnbindTexture(gridTexRef));
#endif
  
  delete accum_grid;
  delete charge_grid;
  delete solved_grid;
  deallocate<CT>(&data1);
  deallocate<CT>(&data2);

#if CUDA_VERSION >= 6000
  if (multi_gpu) {
    delete [] host_data;
    delete [] host_tmp;
#ifndef USE_FBFFT
    cufftCheck(cufftXtFree(multi_data));
#endif
  }
#endif

  if (fft_type == COLUMN) {
    delete xfft_grid;
    delete yfft_grid;
    delete zfft_grid;
#ifndef USE_FBFFT
    cufftCheck(cufftDestroy(x_r2c_plan));
    cufftCheck(cufftDestroy(y_c2c_plan));
    cufftCheck(cufftDestroy(z_c2c_plan));
    cufftCheck(cufftDestroy(x_c2r_plan));
#endif
  } else if (fft_type == SLAB) {
    delete xyfft_grid;
    delete zfft_grid;
#ifndef USE_FBFFT
    cufftCheck(cufftDestroy(xy_r2c_plan));
    cufftCheck(cufftDestroy(z_c2c_plan));
    cufftCheck(cufftDestroy(xy_c2r_plan));
#endif
  } else if (fft_type == BOX) {
    delete fft_grid;
#ifndef USE_FBFFT
    cufftCheck(cufftDestroy(r2c_plan));
    cufftCheck(cufftDestroy(c2r_plan));
#endif
  }

  deallocate<CT>(&prefac_x);
  deallocate<CT>(&prefac_y);
  deallocate<CT>(&prefac_z);

#ifdef USE_NEW_SPREAD
  deallocate<int>(&coordIndGrid);
  if (coordIndOverflow != NULL) deallocate<int>(&coordIndOverflow);
#endif

  //if (d_energy_virial != NULL) deallocate<RecipEnergyVirial_t>(&d_energy_virial);
  //if (h_energy_virial != NULL) deallocate_host<RecipEnergyVirial_t>(&h_energy_virial);
}

template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::print_info() {
  std::cout << "fft_type = ";
  if (fft_type == COLUMN) {
    std::cout << "COLUMN";
  } else if (fft_type == SLAB) {
    std::cout << "SLAB";
  } else {
    std::cout << "BOX";
  }
#ifdef USE_FBFFT
  std::cout << " computed using FBFFT" << std::endl;
#else
  std::cout << " computed using cuFFT" << std::endl;
#endif
  std::cout << "order = " << order << std::endl;
  std::cout << "nfftx, nffty, nfftz = " << nfftx << " " << nffty << " " << nfftz << std::endl;
  std::cout << "x0...x1   = " << x0 << " ... " << x1 << std::endl;
  std::cout << "y0...y1   = " << y0 << " ... " << y1 << std::endl;
  std::cout << "z0...z1   = " << z0 << " ... " << z1 << std::endl;
  std::cout << "xlo...xhi = " << xlo << " ... " << xhi << std::endl;
  std::cout << "ylo...yhi = " << ylo << " ... " << yhi << std::endl;
  std::cout << "zlo...zhi = " << zlo << " ... " << zhi << std::endl;
  std::cout << "xsize, ysize, zsize = " << xsize << " " << ysize << " " << zsize << std::endl;
  std::cout << "data_size = " << data_size << std::endl;
}

/*
//
// Spreads charge on grid. Uses pre-calculated B-splines (slower)
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::spread_charge(const int ncoord, const Bspline<CT> &bspline) {

  AT *dest = (typeid(AT) != typeid(CT)) ? (AT *)accum_grid->data : (AT *)charge_grid->data;

  clear_gpu_array<AT>(dest, xsize*ysize*zsize, stream);

  dim3 nthread, nblock;

  nthread.x = 32;
  nthread.y = 4;
  nthread.z = 1;
  nblock.x = (ncoord - 1)/nthread.x + 1;
  nblock.y = 1;
  nblock.z = 1;

  size_t shmem_size = sizeof(spread_t)*nthread.x;

  switch(order) {
  case 4:
    spread_charge_4<AT> <<< nblock, nthread, shmem_size, stream >>>
      (ncoord, 
       bspline.gix, bspline.giy, bspline.giz,
       bspline.charge,
       (float4 *)bspline.thetax,
       (float4 *)bspline.thetay,
       (float4 *)bspline.thetaz,
       nfftx, nffty, nfftz, dest);
    break;

  default:
    std::cerr<<"CudaPMERecip::spread_charge: order "<<order<<" not implemented"<<std::endl;
    exit(1);
  }
  cudaCheck(cudaGetLastError());

  if (typeid(AT) != typeid(CT)) {
    // Reduce charge data back to a float/double value
    nthread.x = 512;
    nthread.y = 1;
    nthread.z = 1;
    nblock.x = (nfftx*nffty*nfftz - 1)/nthread.x + 1;
    nblock.y = 1;
    nblock.z = 1;
    reduce_force<AT, CT> <<< nblock, nthread, 0, stream >>>(xsize*ysize*zsize,
  							  (AT *)accum_grid->data,
  							  charge_grid->data);
    cudaCheck(cudaGetLastError());
  }

}
*/

//
// Spreads charge on grid. Calculates B-splines on-the-fly (faster)
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::spread_charge(const float4 *xyzq, const int ncoord, const double *recip) {

  AT *dest = (typeid(AT) != typeid(CT)) ? (AT *)accum_grid->data : (AT *)charge_grid->data;

#ifdef USE_NEW_SPREAD
  reallocate<int>(&coordIndOverflow, &coordIndOverflow_len, ncoord, 1.2f);
  clear_gpu_array<int>(coordIndGrid, xsize*ysize*zsize + 1, stream);
#else
  clear_gpu_array<AT>(dest, xsize*ysize*zsize, stream);
#endif

  dim3 nthread, nblock;

  CT recip1 = (CT)recip[0];
  CT recip2 = (CT)recip[4];
  CT recip3 = (CT)recip[8];

  switch(order) {
  case 4:
#ifdef USE_NEW_SPREAD
    nthread.x = 256;
    nthread.y = 1;
    nthread.z = 1;
    nblock.x = (ncoord - 1)/nthread.x + 1;
    nblock.y = 1;
    nblock.z = 1;
    place_charges_ortho<<< nblock, nthread, 0, stream >>>
    (xyzq, ncoord, recip1, recip2, recip3,
      nfftx, nffty, nfftz, xsize, ysize,
      coordIndGrid, coordIndOverflow, (unsigned int *)&coordIndGrid[xsize*ysize*zsize]);
    cudaCheck(cudaGetLastError());

    nthread.x = nfftx;
    nthread.y = 1;
    nthread.z = 1;
    nblock.x = 1;
    nblock.y = ysize;
    nblock.z = zsize;
    spread_charge_ortho<AT, 4> <<< nblock, nthread, 0, stream >>>
      (xyzq, ncoord, recip1, recip2, recip3,
       nfftx, nffty, nfftz, xsize, ysize, coordIndGrid, dest);
    cudaCheck(cudaGetLastError());

    nthread.x = 32;
    nthread.y = 4;
    nthread.z = 1;
    nblock.x = (ncoord*0.1 - 1)/nthread.x + 1;
    nblock.y = 1;
    nblock.z = 1;
    spread_overflow_charge_ortho<AT, 4> <<< nblock, nthread, 0, stream >>>
      (xyzq, ncoord, recip1, recip2, recip3,
       nfftx, nffty, nfftz, xsize, ysize,
       coordIndOverflow, (unsigned int *)&coordIndGrid[xsize*ysize*zsize], dest);
    cudaCheck(cudaGetLastError());
#else
    nthread.x = 32;
    nthread.y = 4;
    nthread.z = 1;
    nblock.x = (ncoord - 1)/nthread.x + 1;
    nblock.y = 1;
    nblock.z = 1;
    // spread_charge_ortho_4<AT> <<< nblock, nthread, 0, stream >>>
    //   (xyzq, ncoord, recip1, recip2, recip3,
    //    nfftx, nffty, nfftz,
    //    (AT *)accum_grid->data);
    spread_charge_ortho<AT, 4> <<< nblock, nthread, 0, stream >>>
      (xyzq, ncoord, recip1, recip2, recip3,
       nfftx, nffty, nfftz, xsize, ysize, dest);
    cudaCheck(cudaGetLastError());
#endif
    break;

  case 6:
    nthread.x = 32;
    nthread.y = 7;
    nthread.z = 1;
    nblock.x = (ncoord - 1)/nthread.x + 1;
    nblock.y = 1;
    nblock.z = 1;
    // spread_charge_ortho_6<AT> <<< nblock, nthread, 0, stream >>>
    //   (xyzq, ncoord, recip1, recip2, recip3,
    //    nfftx, nffty, nfftz,
    //    (AT *)accum_grid->data);
    spread_charge_ortho<AT, 6> <<< nblock, nthread, 0, stream >>>
      (xyzq, ncoord, recip1, recip2, recip3,
       nfftx, nffty, nfftz, xsize, ysize, dest);
    cudaCheck(cudaGetLastError());
    break;

  case 8:
    nthread.x = 32;
    nthread.y = 16;
    nthread.z = 1;
    nblock.x = (ncoord - 1)/nthread.x + 1;
    nblock.y = 1;
    nblock.z = 1;
    // spread_charge_ortho_8<AT> <<< nblock, nthread, 0, stream >>>
    //   (xyzq, ncoord, recip1, recip2, recip3,
    //    nfftx, nffty, nfftz,
    //    (AT *)accum_grid->data);
    spread_charge_ortho<AT, 8> <<< nblock, nthread, 0, stream >>>
      (xyzq, ncoord, recip1, recip2, recip3,
       nfftx, nffty, nfftz, xsize, ysize, dest);
    cudaCheck(cudaGetLastError());
    break;

  default:
    std::cerr<<"CudaPMERecip::spread_charge: order "<<order<<" not implemented"<<std::endl;
    exit(1);
  }

  if (typeid(AT) != typeid(CT)) {
    // Reduce charge data back to a float/double value
    nthread.x = 512;
    nthread.y = 1;
    nthread.z = 1;
    nblock.x = (nfftx*nffty*nfftz - 1)/nthread.x + 1;
    nblock.y = 1;
    nblock.z = 1;
    reduce_force<AT, CT> <<< nblock, nthread, 0, stream >>>
      (xsize*ysize*zsize,
       (AT *)accum_grid->data,
       charge_grid->data);
    cudaCheck(cudaGetLastError());
  }

}

//
// Perform scalar sum
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::scalar_sum(const double *recip, const double kappa,
					   const bool calc_energy, const bool calc_virial) {

  bool calc_energy_virial = (calc_energy || calc_virial);

  // Best performance:
  // cuda_arch = 200:
  // energy & virial & (C2075 | K40c) & 512x14: 102.7 (C2075) | 70.4 (K240c)
  // C2075 & 768x12: 27.4

  int nthread = 512;
  int nblock = 10;

  if (get_cuda_arch() < 300) {
    if (calc_energy_virial) {
      nthread = 512;
      nblock = 14;
    } else {
      nthread = 768;
      nblock = 12;
    }
  } else {
    if (calc_energy_virial) {
      nthread = 1024;
      nblock = 14;
    } else {
      nthread = 1024;
      nblock = 14;
    }
  }

  int shmem_size = sizeof(CT)*(nfftx + nffty + nfftz);
  if (calc_energy_virial) {
    if (get_cuda_arch() < 300) {
      shmem_size = max(shmem_size, (int)(nthread*sizeof(RecipVirial_t)));
    } else {
      shmem_size = max(shmem_size, (int)((nthread/warpsize)*sizeof(RecipVirial_t)));
    }
  }

  int nfft1, nfft2, nfft3;
  int size1, size2, size3;
  CT *prefac1, *prefac2, *prefac3;
  CT recip1, recip2, recip3;
  CT2 *datap;

  if (fft_type == COLUMN || fft_type == SLAB) {
    nfft1 = nfftz;
    nfft2 = nfftx;
    nfft3 = nffty;
    size1 = nfftz;
    size2 = nfftx/2+1;
    size3 = nffty;
    prefac1 = prefac_z;
    prefac2 = prefac_x;
    prefac3 = prefac_y;
    recip1 = (CT)recip[8];
    recip2 = (CT)recip[0];
    recip3 = (CT)recip[4];
    datap = zfft_grid->data;
  } else if (fft_type == BOX) {
    nfft1 = nfftx;
    nfft2 = nffty;
    nfft3 = nfftz;
    size1 = nfftx/2+1;
    size2 = nffty;
    size3 = nfftz;
    prefac1 = prefac_x;
    prefac2 = prefac_y;
    prefac3 = prefac_z;
    recip1 = (CT)recip[0];
    recip2 = (CT)recip[4];
    recip3 = (CT)recip[8];
    datap = fft_grid->data;
  }

  bool ortho = (recip[1] == 0.0 && recip[2] == 0.0 && recip[3] == 0.0 &&
		recip[5] == 0.0 && recip[6] == 0.0 && recip[7] == 0.0);

  double inv_vol = recip[0]*recip[4]*recip[8];
  CT piv_inv = (CT)(inv_vol/pi);
  CT fac = (CT)(pi*pi/(kappa*kappa));

  bool global_base = (x0 == 0 && y0 == 0 && z0 == 0);

  int nf1 = nfft1/2 + (nfft1 % 2);
  int nf2 = nfft2/2 + (nfft2 % 2);
  int nf3 = nfft3/2 + (nfft3 % 2);

  if (ortho) {
    if (calc_energy_virial) {
      scalar_sum_ortho_kernel<CT, CT2, true>
	<<< nblock, nthread, shmem_size, stream >>>
	(nfft1, nfft2, nfft3,
	 size1, size2, size3,
	 nf1, nf2, nf3,
	 recip1, recip2, recip3,
	 prefac1, prefac2, prefac3,
	 fac, piv_inv, global_base, datap,
	 energyVirial.getEnergyPointer(strRecip),
	 energyVirial.getVirialPointer());
      cudaCheck(cudaGetLastError());
    } else {
      scalar_sum_ortho_kernel<CT, CT2, false>
	<<< nblock, nthread, shmem_size, stream >>>
	(nfft1, nfft2, nfft3,
	 size1, size2, size3,
	 nf1, nf2, nf3,
	 recip1, recip2, recip3,
	 prefac1, prefac2, prefac3,
	 fac, piv_inv, global_base, datap, NULL, NULL);
      cudaCheck(cudaGetLastError());
    }
  } else {
    std::cerr<<"CudaPMERecip::scalar_sum: only orthorombic boxes are currently supported"<<std::endl;
    exit(1);
  }

}

//
// Calculates self energy
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::calc_self_energy(const float4 *xyzq, const int ncoord, const double kappa) {
  int nthread = 256;
  int nblock = (ncoord-1)/nthread+1;
  int shmem_size = nthread*sizeof(double);
  double kappa_ccelec_sqrtpi = kappa*ccelec/sqrt(pi);
  calc_self_energy_kernel<<< nblock, nthread, shmem_size, stream >>>
    (ncoord, xyzq, kappa_ccelec_sqrtpi, energyVirial.getEnergyPointer(strSelf));
  cudaCheck(cudaGetLastError());
}

/*
//
// Gathers forces from the grid
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::gather_force(const int ncoord, const double* recip,
				     const Bspline<CT> &bspline,
				     const int stride, CT* force) {

  dim3 nthread(32, 2, 1);
  dim3 nblock((ncoord - 1)/nthread.x + 1, 1, 1);
  size_t shmem_size = sizeof(gather_t<CT, 4>)*nthread.x + sizeof(float3)*nthread.x*nthread.y;

  CT recip_loc[9];
  recip_loc[0] = (CT)(recip[0]*(double)nfftx*ccelec);
  recip_loc[1] = (CT)(recip[1]*(double)nfftx*ccelec);
  recip_loc[2] = (CT)(recip[2]*(double)nfftx*ccelec);
  recip_loc[3] = (CT)(recip[3]*(double)nffty*ccelec);
  recip_loc[4] = (CT)(recip[4]*(double)nffty*ccelec);
  recip_loc[5] = (CT)(recip[5]*(double)nffty*ccelec);
  recip_loc[6] = (CT)(recip[6]*(double)nfftz*ccelec);
  recip_loc[7] = (CT)(recip[7]*(double)nfftz*ccelec);
  recip_loc[8] = (CT)(recip[8]*(double)nfftz*ccelec);

  bool ortho = (recip[1] == 0.0 && recip[2] == 0.0 && recip[3] == 0.0 &&
		recip[5] == 0.0 && recip[6] == 0.0 && recip[7] == 0.0);

  if (ortho) {
    switch(order) {
    case 4:
      gather_force_4_ortho_kernel<CT> 
	<<< nblock, nthread, shmem_size, stream >>>
	(ncoord,
	 nfftx, nffty, nfftz,
	 nfftx, nffty, nfftz,
	 recip_loc[0], recip_loc[4], recip_loc[8],
	 bspline.gix, bspline.giy, bspline.giz, bspline.charge,
	 (float4 *)bspline.thetax,
	 (float4 *)bspline.thetay,
	 (float4 *)bspline.thetaz,
	 (float4 *)bspline.dthetax,
	 (float4 *)bspline.dthetay,
	 (float4 *)bspline.dthetaz,
#ifdef USE_TEXTURE_OBJECTS
	 gridTexObj,
#endif
	 stride, force);
      break;

    default:
      std::cerr<<"CudaPMERecip::gather_force: order "<<order<<" not implemented"<<std::endl;
      exit(1);
    }
  } else {
      std::cerr<<"CudaPMERecip::gather_force: only orthorombic boxes are currently supported"<<std::endl;
      std::cerr<<recip[1]<<std::endl;
      std::cerr<<recip[2]<<std::endl;
      std::cerr<<recip[3]<<std::endl;
      std::cerr<<recip[5]<<std::endl;
      std::cerr<<recip[6]<<std::endl;
      std::cerr<<recip[7]<<std::endl;
      exit(1);    
  }

  cudaCheck(cudaGetLastError());
}
*/

//
// Gathers forces from the grid
//
template <typename AT, typename CT, typename CT2>
template <typename FT>
void CudaPMERecip<AT, CT, CT2>::gather_force(const float4 *xyzq, const int ncoord, const double* recip,
				     const int stride, FT* force) {

  dim3 nthread(32, 2, 1);
  dim3 nblock((ncoord - 1)/nthread.x + 1, 1, 1);
  //size_t shmem_size = sizeof(gather_t<CT>)*nthread.x;// + sizeof(float3)*nthread.x*nthread.y;

  CT recip_loc[9];
  recip_loc[0] = (CT)(recip[0]);
  recip_loc[1] = (CT)(recip[1]);
  recip_loc[2] = (CT)(recip[2]);
  recip_loc[3] = (CT)(recip[3]);
  recip_loc[4] = (CT)(recip[4]);
  recip_loc[5] = (CT)(recip[5]);
  recip_loc[6] = (CT)(recip[6]);
  recip_loc[7] = (CT)(recip[7]);
  recip_loc[8] = (CT)(recip[8]);

  CT ccelec_loc = (CT)ccelec;

  bool ortho = (recip[1] == 0.0 && recip[2] == 0.0 && recip[3] == 0.0 &&
		recip[5] == 0.0 && recip[6] == 0.0 && recip[7] == 0.0);

  if (ortho) {
    switch(order) {
    case 4:
//       gather_force_4_ortho_kernel<CT, FT> 
// 	<<< nblock, nthread, 0, stream >>>
// 	(xyzq, ncoord,
// 	 nfftx, nffty, nfftz,
// 	 nfftx, nffty, nfftz,
// 	 recip_loc[0], recip_loc[4], recip_loc[8],
// 	 ccelec_loc,
// #ifdef USE_TEXTURE_OBJECTS
// 	 gridTexObj,
// #endif
// 	 stride, force);
      gather_force_ortho<CT, FT, 4> 
  <<< nblock, nthread, 0, stream >>>
  (xyzq, ncoord,
   nfftx, nffty, nfftz,
   nfftx, nffty, nfftz,
   recip_loc[0], recip_loc[4], recip_loc[8],
   ccelec_loc,
#ifdef USE_TEXTURE_OBJECTS
   gridTexObj,
#endif
   stride, force);
      break;

    case 6:
//       gather_force_6_ortho_kernel<CT, FT> 
// 	<<< nblock, nthread, 0, stream >>>
// 	(xyzq, ncoord,
// 	 nfftx, nffty, nfftz,
// 	 nfftx, nffty, nfftz,
// 	 recip_loc[0], recip_loc[4], recip_loc[8],
// 	 ccelec_loc,
// #ifdef USE_TEXTURE_OBJECTS
// 	 gridTexObj,
// #endif
// 	 stride, force);
      gather_force_ortho<CT, FT, 6> 
  <<< nblock, nthread, 0, stream >>>
  (xyzq, ncoord,
   nfftx, nffty, nfftz,
   nfftx, nffty, nfftz,
   recip_loc[0], recip_loc[4], recip_loc[8],
   ccelec_loc,
#ifdef USE_TEXTURE_OBJECTS
   gridTexObj,
#endif
   stride, force);
      break;
 
    case 8:
//       gather_force_8_ortho_kernel<CT, FT> 
// 	<<< nblock, nthread, 0, stream >>>
// 	(xyzq, ncoord,
// 	 nfftx, nffty, nfftz,
// 	 nfftx, nffty, nfftz,
// 	 recip_loc[0], recip_loc[4], recip_loc[8],
// 	 ccelec_loc,
// #ifdef USE_TEXTURE_OBJECTS
// 	 gridTexObj,
// #endif
// 	 stride, force);
      gather_force_ortho<CT, FT, 8> 
  <<< nblock, nthread, 0, stream >>>
  (xyzq, ncoord,
   nfftx, nffty, nfftz,
   nfftx, nffty, nfftz,
   recip_loc[0], recip_loc[4], recip_loc[8],
   ccelec_loc,
#ifdef USE_TEXTURE_OBJECTS
   gridTexObj,
#endif
   stride, force);
      break;

    default:
      std::cerr<<"CudaPMERecip::gather_force: order "<<order<<" not implemented"<<std::endl;
      exit(1);
    }
  } else {
      std::cerr<<"CudaPMERecip::gather_force: only orthorombic boxes are currently supported"<<std::endl;
      std::cerr<<recip[1]<<std::endl;
      std::cerr<<recip[2]<<std::endl;
      std::cerr<<recip[3]<<std::endl;
      std::cerr<<recip[5]<<std::endl;
      std::cerr<<recip[6]<<std::endl;
      std::cerr<<recip[7]<<std::endl;
      exit(1);    
  }

  cudaCheck(cudaGetLastError());
}

//
// FFT x coordinate Real -> Complex
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::x_fft_r2c(CT2 *data) {

  if (fft_type == COLUMN) {
#ifdef USE_FBFFT
    using namespace facebook::cuda::fbfft;
    int dataInSize[2] = {x_r2c_batchSize, x_r2c_nfft};
    int dataOutSize[3] = {x_r2c_batchSize, x_r2c_nfft/2+1, 2};
    DeviceTensor<float, 2> dataInTensor((float *)data, dataInSize);
    DeviceTensor<float, 3> dataOutTensor((float *)data, dataOutSize);
    fbfftCheck(fbfft1D<1>(dataInTensor, dataOutTensor, stream));
#else // !USE_FBFFT
    cufftCheck(cufftExecR2C(x_r2c_plan,
			    (cufftReal *)data,
			    (cufftComplex *)data));
#endif // USE_FBFFT
  } else {
    std::cerr << "CudaPMERecip::x_fft_r2c, only COLUMN type FFT can call this function" << std::endl;
    exit(1);
  }

}

//
// FFT x coordinate Complex -> Real
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::x_fft_c2r(CT2 *data) {

  if (fft_type == COLUMN) {
#ifdef USE_FBFFT
    using namespace facebook::cuda::fbfft;
    int dataInSize[2] = {x_c2r_batchSize, x_c2r_nfft};
    int dataOutSize[3] = {x_c2r_batchSize, x_c2r_nfft/2+1, 2};
    DeviceTensor<float, 2> dataInTensor((float *)data, dataInSize);
    DeviceTensor<float, 3> dataOutTensor((float *)data, dataOutSize);
    fbfftCheck(fbifft1D<1>(dataInTensor, dataOutTensor, stream));
#else
    cufftCheck(cufftExecC2R(x_c2r_plan,
			    (cufftComplex *)data,
			    (cufftReal *)data));
#endif
  } else {
    std::cerr << "CudaPMERecip::x_fft_c2r, only COLUMN type FFT can call this function" << std::endl;
    exit(1);
  }

}

//
// FFT y coordinate Complex -> Complex
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::y_fft_c2c(CT2 *data, const int direction) {

  if (fft_type == COLUMN) {
#ifdef USE_FBFFT
#else
    cufftCheck(cufftExecC2C(y_c2c_plan,
			    (cufftComplex *)data,
			    (cufftComplex *)data,
			    direction));
#endif
  } else {
    std::cerr << "CudaPMERecip::y_fft_c2c, only COLUMN type FFT can call this function" << std::endl;
    exit(1);
  }

}

//
// FFT z coordinate Complex -> Complex
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::z_fft_c2c(CT2 *data, const int direction) {

  if (fft_type == COLUMN) {
#ifdef USE_FBFFT
#else
    cufftCheck(cufftExecC2C(z_c2c_plan,
			    (cufftComplex *)data,
			    (cufftComplex *)data,
			    direction));
#endif
  } else {
    std::cerr << "CudaPMERecip::z_fft_c2c, only COLUMN type FFT can call this function" << std::endl;
    exit(1);
  }

}

//
// 3D FFT Real -> Complex
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::r2c_fft() {

  if (fft_type == COLUMN) {
    // data2(x, y, z)
    x_fft_r2c(xfft_grid->data);
    xfft_grid->transpose_xyz_yzx(yfft_grid);

    // data1(y, z, x)
    y_fft_c2c(yfft_grid->data, CUFFT_FORWARD);
    yfft_grid->transpose_xyz_yzx(zfft_grid);

    // data2(z, x, y)
    z_fft_c2c(zfft_grid->data, CUFFT_FORWARD);
  } else if (fft_type == SLAB) {
#ifdef USE_FBFFT
    /*
    using namespace facebook::cuda::fbfft;
    int dataInSize[2] = {x_r2c_batchSize, x_r2c_nfft};
    int dataOutSize[3] = {x_r2c_batchSize, x_r2c_nfft/2+1, 2};
    DeviceTensor<float, 2> dataInTensor((float *)data, dataInSize);
    DeviceTensor<float, 3> dataOutTensor((float *)data, dataOutSize);
    fbfftCheck(fbfft1D<1>(dataInTensor, dataOutTensor, stream));
    */
    std::cerr << "CudaPMERecip::r2c_fft, slab FFT not yet implemented for FBFFT" << std::endl;
    exit(1);
#else // !USE_FBFFT
    cufftCheck(cufftExecR2C(xy_r2c_plan,
			    (cufftReal *)charge_grid->data,
			    (cufftComplex *)xyfft_grid->data));
    xyfft_grid->transpose_xyz_zxy(zfft_grid);
    cufftCheck(cufftExecC2C(z_c2c_plan,
			    (cufftComplex *)zfft_grid->data,
			    (cufftComplex *)zfft_grid->data, CUFFT_FORWARD));
#endif // USE_FBFFT
  } else if (fft_type == BOX) {
#ifdef USE_FBFFT
    std::cerr << "CudaPMERecip::r2c_fft, 3D FFT not implemented for FBFFT" << std::endl;
    exit(1);
#else // !USE_FBFFT
    if (multi_gpu) {
#if CUDA_VERSION >= 6000
      // Transform from Real -> Complex
      cudaCheck(cudaMemcpy(host_tmp, charge_grid->data, sizeof(CT)*xsize*ysize*zsize,
			   cudaMemcpyDeviceToHost));
      for (int z=0;z < zsize;z++)
        for (int y=0;y < ysize;y++)
          for (int x=0;x < xsize;x++) {
            host_data[x + (y + z*ysize)*xsize].x = host_tmp[x + (y + z*ysize)*xsize];
            host_data[x + (y + z*ysize)*xsize].y = 0;
          }

      cufftCheck(cufftXtMemcpy(r2c_plan, multi_data, host_data, CUFFT_COPY_HOST_TO_DEVICE));
      cufftCheck(cufftXtExecDescriptorC2C(r2c_plan,
					  multi_data,
					  multi_data, CUFFT_FORWARD));
      // Copy data back to a single GPU buffer in fft_grid->data
      cufftCheck(cufftXtMemcpy(r2c_plan, host_data, multi_data, CUFFT_COPY_DEVICE_TO_HOST));

      CT2 *tmp = (CT2 *)host_tmp;
      for (int z=0;z < zsize;z++)
        for (int y=0;y < ysize;y++)
          for (int x=0;x < xsize/2+1;x++) {
            tmp[x + (y + z*ysize)*(xsize/2+1)].x = host_data[x + (y + z*ysize)*xsize].x;
            tmp[x + (y + z*ysize)*(xsize/2+1)].y = host_data[x + (y + z*ysize)*xsize].y;
          }
      cudaCheck(cudaMemcpy(fft_grid->data, tmp, sizeof(CT2)*(xsize/2+1)*ysize*zsize,
			   cudaMemcpyHostToDevice));
#endif
    } else {
      cufftCheck(cufftExecR2C(r2c_plan,
			      (cufftReal *)charge_grid->data,
			      (cufftComplex *)fft_grid->data));
    }
#endif // USE_FBFFT
  }
}

//
// 3D FFT Complex -> Real
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::c2r_fft() {

  if (fft_type == COLUMN) {
    // data2(z, x, y)
    z_fft_c2c(zfft_grid->data, CUFFT_INVERSE);
    zfft_grid->transpose_xyz_zxy(yfft_grid);

    // data1(y, x, z)
    y_fft_c2c(yfft_grid->data, CUFFT_INVERSE);
    yfft_grid->transpose_xyz_zxy(xfft_grid);

    // data2(x, y, z)
    x_fft_c2r(xfft_grid->data);
  } else if (fft_type == SLAB) {
#ifdef USE_FBFFT
    std::cerr << "CudaPMERecip::c2c_fft, slab FFT not yet implemented for FBFFT" << std::endl;
    exit(1);
#else // !USE_FBFFT
    cufftCheck(cufftExecC2C(z_c2c_plan,
			    (cufftComplex *)zfft_grid->data,
			    (cufftComplex *)zfft_grid->data, CUFFT_INVERSE));
    zfft_grid->transpose_xyz_yzx(xyfft_grid);
    cufftCheck(cufftExecC2R(xy_c2r_plan,
			    (cufftComplex *)xyfft_grid->data,
			    (cufftReal *)xyfft_grid->data));
#endif // USE_FBFFT
  } else if (fft_type == BOX) {
#ifdef USE_FBFFT
    std::cerr << "CudaPMERecip::c2c_fft, 3D FFT not implemented for FBFFT" << std::endl;
    exit(1);
#else // !USE_FBFFT
    cufftCheck(cufftExecC2R(c2r_plan,
			    (cufftComplex *)fft_grid->data,
			    (cufftReal *)fft_grid->data));
#endif // USE_FBFFT
  }

}

//
// Sets Bspline order
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::set_order(int order) {
  this->order = order;
  calc_prefac();
}

void dftmod(double *bsp_mod, const double *bsp_arr, const int nfft) {

  const double rsmall = 1.0e-10;
  double nfftr = (2.0*3.14159265358979323846)/(double)nfft;

  for (int k=1;k <= nfft;k++) {
    double sum1 = 0.0;
    double sum2 = 0.0;
    double arg1 = (k-1)*nfftr;
    for (int j=1;j < nfft;j++) {
      double arg = arg1*(j-1);
      sum1 += bsp_arr[j-1]*cos(arg);
      sum2 += bsp_arr[j-1]*sin(arg);
    }
    bsp_mod[k-1] = sum1*sum1 + sum2*sum2;
  }

  for (int k=1;k <= nfft;k++)
    if (bsp_mod[k-1] < rsmall)
      bsp_mod[k-1] = 0.5*(bsp_mod[k-1-1] + bsp_mod[k+1-1]);

  for (int k=1;k <= nfft;k++)
    bsp_mod[k-1] = 1.0/bsp_mod[k-1];

}

void fill_bspline_host(const int order, const double w, double *array, double *darray) {

  //--- do linear case
  array[order-1] = 0.0;
  array[2-1] = w;
  array[1-1] = 1.0 - w;

  //--- compute standard b-spline recursion
  for (int k=3;k <= order-1;k++) {
    double div = 1.0 / (double)(k-1);
    array[k-1] = div*w*array[k-1-1];
    for (int j=1;j <= k-2;j++)
      array[k-j-1] = div*((w+j)*array[k-j-1-1] + (k-j-w)*array[k-j-1]);
    array[1-1] = div*(1.0-w)*array[1-1];
  }

  //--- perform standard b-spline differentiation
  darray[1-1] = -array[1-1];
  for (int j=2;j <= order;j++)
    darray[j-1] = array[j-1-1] - array[j-1];

  //--- one more recursion
  int k = order;
  double div = 1.0 / (double)(k-1);
  array[k-1] = div*w*array[k-1-1];
  for (int j=1;j <= k-2;j++)
    array[k-j-1] = div*((w+j)*array[k-j-1-1] + (k-j-w)*array[k-j-1]);

  array[1-1] = div*(1.0-w)*array[1-1];

}

//
// Calculates (prefac_x, prefac_y, prefac_z)
// NOTE: This calculation is done on the CPU since it is only done infrequently
//
template <typename AT, typename CT, typename CT2>
void CudaPMERecip<AT, CT, CT2>::calc_prefac() {
  
  int max_nfft = max(nfftx, max(nffty, nfftz));
  double *bsp_arr = new double[max_nfft];
  double *bsp_mod = new double[max_nfft];
  double *array = new double[order];
  double *darray = new double[order];
  CT *h_prefac_x = new CT[nfftx];
  CT *h_prefac_y = new CT[nffty];
  CT *h_prefac_z = new CT[nfftz];

  fill_bspline_host(order, 0.0, array, darray);
  for (int i=0;i < max_nfft;i++) bsp_arr[i] = 0.0;
  for (int i=2;i <= order+1;i++) bsp_arr[i-1] = array[i-1-1];

  dftmod(bsp_mod, bsp_arr, nfftx);
  for (int i=0;i < nfftx;i++) h_prefac_x[i] = (CT)bsp_mod[i];

  dftmod(bsp_mod, bsp_arr, nffty);
  for (int i=0;i < nffty;i++) h_prefac_y[i] = (CT)bsp_mod[i];

  dftmod(bsp_mod, bsp_arr, nfftz);
  for (int i=0;i < nfftz;i++) h_prefac_z[i] = (CT)bsp_mod[i];

  copy_HtoD<CT>(h_prefac_x, prefac_x, nfftx);
  copy_HtoD<CT>(h_prefac_y, prefac_y, nffty);
  copy_HtoD<CT>(h_prefac_z, prefac_z, nfftz);

  delete [] bsp_arr;
  delete [] bsp_mod;
  delete [] array;
  delete [] darray;
  delete [] h_prefac_x;
  delete [] h_prefac_y;
  delete [] h_prefac_z;
}

//
// Explicit instances of CudaPMERecip
//
template class CudaPMERecip<long long int, float, float2>;
template class CudaPMERecip<int, float, float2>;
template class CudaPMERecip<float, float, float2>;

template void CudaPMERecip<float, float, float2>::gather_force<float>(const float4 *xyzq, const int ncoord,
                    const double* recip,
                    const int stride, float* force);

template void CudaPMERecip<int, float, float2>::gather_force<float>(const float4 *xyzq, const int ncoord,
								    const double* recip,
								    const int stride, float* force);
template void CudaPMERecip<int, float, float2>::gather_force<long long int>(const float4 *xyzq, const int ncoord,
									    const double* recip,
									    const int stride, long long int* force);
template void CudaPMERecip<int, float, float2>::gather_force<float3>(const float4 *xyzq, const int ncoord,
								     const double* recip,
								     const int stride, float3* force);

