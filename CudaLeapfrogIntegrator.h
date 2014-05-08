#ifndef CUDALEAPFROGINTEGRATOR_H
#define CUDALEAPFROGINTEGRATOR_H
#include <cuda.h>
#include "LeapfrogIntegrator.h"
#include "cudaXYZ.h"
#include "Force.h"
#include "CudaPMEForcefield.h"

class CudaLeapfrogIntegrator : public LeapfrogIntegrator {

  //friend class LangevinPiston;

private:

  // Coordinates
  cudaXYZ<double> coord;

  // Previous step coordinates
  cudaXYZ<double> prev_coord;

  // Step vector
  cudaXYZ<double> step;

  // Previous step vector 
  cudaXYZ<double> prev_step;

  // Mass
  float *mass;

  // Force array
  Force<long long int> force;

  // Force field
  CudaForcefield *forcefield;

  cudaEvent_t copy_rms_work_done_event;
  cudaEvent_t copy_temp_ekin_done_event;

  cudaStream_t stream;

  void swap_step();
  void take_step();
  void calc_step();
  void calc_force(const bool calc_energy, const bool calc_virial);

public:

  CudaLeapfrogIntegrator(cudaStream_t stream=0);
  ~CudaLeapfrogIntegrator();

  void init(const int ncoord,
	    const double *x, const double *y, const double *z,
	    const double *dx, const double *dy, const double *dz);

};

#endif // CUDALEAPFROGINTEGRATOR_H
