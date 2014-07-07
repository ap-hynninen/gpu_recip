
#ifndef REDUCE_H
#define REDUCE_H

//----------------------------------------------------------------------------------------

template <typename AT, typename CT>
  __global__ void reduce_force(const int n,
			       const int stride_in,
			       const AT* __restrict__ data_in,
			       const int stride_out,
			       CT* __restrict__ data_out);

//----------------------------------------------------------------------------------------

template <typename AT, typename CT>
  __global__ void reduce_force(const int nfft_tot,
			       const AT* __restrict__ data_in,
			       CT* __restrict__ data_out);

//----------------------------------------------------------------------------------------

template <typename AT, typename CT>
  __global__ void reduce_force(const int nfft_tot,
			       AT* data_in);

//----------------------------------------------------------------------------------------

template <typename AT, typename CT1, typename CT2>
  __global__ void reduce_add_force(const int nfft_tot,
				   const CT2* __restrict__ data_add,
				   AT* __restrict__ data_inout);

//----------------------------------------------------------------------------------------

#endif // REDUCE_H
