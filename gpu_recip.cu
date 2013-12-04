#include <iostream>
#include <cuda.h>
#include "gpu_utils.h"
#include "XYZQ.h"
#include "Bspline.h"
#include "Grid.h"

void test();

int main(int argc, char *argv[]) {

  int gpu_ind = 1;
  cudaCheck(cudaSetDevice(gpu_ind));

  cudaCheck(cudaThreadSynchronize());
  
  cudaDeviceProp gpu_prop;
  cudaCheck(cudaGetDeviceProperties(&gpu_prop, gpu_ind));

  printf("Using CUDA device (%d) %s\n",gpu_ind,gpu_prop.name);

  test();

  return 0;
}

//
// Test the code using data in test_data/ -directory
//
void test() {

  // Settings for the data:
  const double boxx = 62.23;
  const double boxy = 62.23;
  const double boxz = 62.23;
  const int nfftx = 64;
  const int nffty = 64;
  const int nfftz = 64;
  const int order = 4;

  // Number of MPI nodes & current node index
  int nnode = 1;
  int mynode = 0;

  double recip[9];
  for (int i=0;i < 9;i++) recip[i] = 0.0;
  recip[0] = 1.0/boxx;
  recip[4] = 1.0/boxy;
  recip[8] = 1.0/boxz;

  // Load comparison data
  Matrix3d<float> q(nfftx, nffty, nfftz, "test_data/q_real_double.txt");
  Matrix3d<float> q_xfft((nfftx/2+1)*2, nffty, nfftz, "test_data/q_comp1_double.txt");

  XYZQ xyzq("test_data/xyzq.txt");

  Bspline<float> bspline(23558, order, recip);
  Grid<long long int, float> grid(nfftx, nffty, nfftz, order, nnode, mynode);

  grid.make_fft_plans();
  grid.print_info();

  bspline.fill_bspline(xyzq.xyzq, xyzq.ncoord, nfftx, nffty, nfftz);

  grid.spread_charge(xyzq.ncoord, bspline);

  float tol = 1.0e-5f;

  if (!q.compare(grid.mat2, tol)) {
    std::cout<< "q comparison FAILED" << std::endl;
    return;
  } else {
    std::cout<< "q comparison OK (tolerance " << tol << ")" << std::endl;
  }

  grid.x_fft_r2c();
  if (!q_xfft.compare(grid.mat2, tol)) {
    std::cout<< "q_xfft comparison FAILED" << std::endl;
    return;
  } else {
    std::cout<< "q_xfft comparison OK (tolerance " << tol << ")" << std::endl;
  }

  //  grid.test_copy();
  //  grid.test_transpose();
  
}
