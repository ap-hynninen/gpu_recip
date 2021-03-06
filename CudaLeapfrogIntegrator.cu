#include <iostream>
#include <cassert>
#include "CudaLeapfrogIntegrator.h"
#include "cuda_utils.h"
#include "gpu_utils.h"

//
// Storage
//
static __device__ CudaLeapfrogIntegrator_storage_t d_CudaLeapfrogIntegrator_storage;

//
// Calculates: a = b + c
//
__global__ void add_coord_kernel(const int n,
				 const double* __restrict__ bx,
				 const double* __restrict__ by,
				 const double* __restrict__ bz,
				 const double* __restrict__ cx,
				 const double* __restrict__ cy,
				 const double* __restrict__ cz,
				 double* __restrict__ ax,
				 double* __restrict__ ay,
				 double* __restrict__ az) {
  const int tid = threadIdx.x + blockIdx.x*blockDim.x;
  if (tid < n) {
    ax[tid] = bx[tid] + cx[tid];
    ay[tid] = by[tid] + cy[tid];
    az[tid] = bz[tid] + cz[tid];
  }
}

//
// Calculates: a = b - c
//
__global__ void sub_coord_kernel(const int n,
				 const double* __restrict__ bx,
				 const double* __restrict__ by,
				 const double* __restrict__ bz,
				 const double* __restrict__ cx,
				 const double* __restrict__ cy,
				 const double* __restrict__ cz,
				 double* __restrict__ ax,
				 double* __restrict__ ay,
				 double* __restrict__ az) {
  const int tid = threadIdx.x + blockIdx.x*blockDim.x;
  if (tid < n) {
    ax[tid] = bx[tid] - cx[tid];
    ay[tid] = by[tid] - cy[tid];
    az[tid] = bz[tid] - cz[tid];
  }
}

//
// Calculates the next step vector using forces:
// step = prev_step - force*dt^2/mass
// gamma_val = dt^2/mass
//
__global__ void calc_step_kernel(const int ncoord, const int stride, 
				 const double dtsq,
				 const double* __restrict__ force,
				 const double* __restrict__ prev_step_x,
				 const double* __restrict__ prev_step_y,
				 const double* __restrict__ prev_step_z,
				 const float* __restrict__ mass,
				 double* __restrict__ step_x,
				 double* __restrict__ step_y,
				 double* __restrict__ step_z) {
  const int tid = threadIdx.x + blockIdx.x*blockDim.x;
  if (tid < ncoord) {
    double gamma_val = dtsq/(double)mass[tid];
    step_x[tid] = prev_step_x[tid] - force[tid]*gamma_val;
    step_y[tid] = prev_step_y[tid] - force[tid+stride]*gamma_val;
    step_z[tid] = prev_step_z[tid] - force[tid+stride*2]*gamma_val;
  }
}

//
// Calculates kinetic energy
//
__global__ void calc_kine_kernel(const int ncoord,
				 const double fac,
				 const float* __restrict__ mass,
				 const double* __restrict__ prev_step_x,
				 const double* __restrict__ prev_step_y,
				 const double* __restrict__ prev_step_z,
				 const double* __restrict__ step_x,
				 const double* __restrict__ step_y,
				 const double* __restrict__ step_z) {

  // Required shared memory:
  // blockDim.x*sizeof(double)
  extern __shared__ double sh_kine[];

  const int tid = threadIdx.x + blockIdx.x*blockDim.x;

  double kine = 0.0;
  if (tid < ncoord) {
    double vx = (prev_step_x[tid] + step_x[tid])*fac;
    double vy = (prev_step_y[tid] + step_y[tid])*fac;
    double vz = (prev_step_z[tid] + step_z[tid])*fac;
    kine = ((double)mass[tid])*(vx*vx + vy*vy + vz*vz);
  }

  sh_kine[threadIdx.x] = kine;
  __syncthreads();
  for (int d=1;d < blockDim.x;d*=2) {
    int t = threadIdx.x + d;
    double kine_val = (t < blockDim.x) ? sh_kine[t] : 0.0;
    __syncthreads();
    sh_kine[threadIdx.x] += kine_val;
    __syncthreads();
  }
  
  if (threadIdx.x == 0) {
    atomicAdd(&d_CudaLeapfrogIntegrator_storage.kine, sh_kine[0]);
  }

}

//##################################################################################################

//
// Class creator
//
CudaLeapfrogIntegrator::CudaLeapfrogIntegrator(HoloConst *holoconst) : holoconst(holoconst) {
  // Create stream & events
  cudaCheck(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));
  cudaCheck(cudaEventCreate(&copy_rms_work_done_event));
  cudaCheck(cudaEventCreate(&copy_temp_ekin_done_event));
  cudaCheck(cudaEventCreate(&done_integrate_event));
  global_mass = NULL;
  mass_len = 0;
  mass = NULL;
  allocate_host<CudaLeapfrogIntegrator_storage_t>(&h_CudaLeapfrogIntegrator_storage, 1);
}

//
// Class destructor
//
CudaLeapfrogIntegrator::~CudaLeapfrogIntegrator() {
  cudaCheck(cudaStreamDestroy(stream));
  cudaCheck(cudaEventDestroy(copy_rms_work_done_event));
  cudaCheck(cudaEventDestroy(copy_temp_ekin_done_event));
  cudaCheck(cudaEventDestroy(done_integrate_event));
  if (global_mass != NULL) deallocate<float>(&global_mass);
  if (mass != NULL) deallocate<float>(&mass);
  deallocate_host<CudaLeapfrogIntegrator_storage_t>(&h_CudaLeapfrogIntegrator_storage);
}

//
// Initialize integrator
//
void CudaLeapfrogIntegrator::spec_init(const double *x, const double *y, const double *z,
				       const double *dx, const double *dy, const double *dz,
				       const double *h_mass) {
  if (forcefield == NULL) {
    std::cerr << "CudaLeapfrogIntegrator::spec_init, no forcefield set!" << std::endl;
    exit(1);
  }

  // Create temporary host array for coordinates
  hostXYZ<double> h_prev_coord(ncoord_glo, NON_PINNED);
  h_prev_coord.set_data_fromhost(ncoord_glo, x, y, z);

  // Initialize force field coordinate arrays and divide atoms to nodes
  std::vector<int> h_loc2glo;
  CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
  p->assignCoordToNodes(h_prev_coord, h_loc2glo);

  ncoord = h_loc2glo.size();
  // For now we set ncoord_tot = ncoord, this will change if there are imported atoms
  ncoord_tot = ncoord;

  // Realloc and set arrays
  step.realloc(ncoord);
  step.clear();

  prev_step.realloc(ncoord);
  prev_step.set_data_sync(h_loc2glo, dx, dy, dz);

  coord.realloc(ncoord);
  coord.clear();

  prev_coord.realloc(ncoord);
  prev_coord.set_data_sync(h_loc2glo, x, y, z);

  force.realloc(ncoord);

  // Make global mass array
  float *h_mass_f = new float[ncoord_glo];
  for (int i=0;i < ncoord_glo;i++) {
    h_mass_f[i] = (float)h_mass[i];
  }
  allocate<float>(&global_mass, ncoord_glo);
  copy_HtoD<float>(h_mass_f, global_mass, ncoord_glo);
  delete [] h_mass_f;

}

//
// Swaps step <=> prev_step
//
void CudaLeapfrogIntegrator::swap_step() {
  assert(step.match(prev_step));

  // Wait here until work on stream has stopped
  cudaCheck(cudaStreamSynchronize(stream));

  step.swap(prev_step);
}

//
// Swaps coord <=> prev_coord
//
void CudaLeapfrogIntegrator::swap_coord() {
  assert(coord.match(prev_coord));

  // Wait here until work on stream has stopped
  cudaCheck(cudaStreamSynchronize(stream));

  coord.swap(prev_coord);
}

//
// Calculates new current coordinate positions (cur) using 
// the previous coordinates (prev) and the step vector (step)
// coord = prev_coord + prev_step
//
void CudaLeapfrogIntegrator::take_step() {

  add_coord(prev_coord, prev_step, coord);
  cudaCheck(cudaEventRecord(done_integrate_event, stream));
}

//
// Calculate step
//
void CudaLeapfrogIntegrator::calc_step() {
  assert(prev_step.match(step));
  assert(ncoord == step.size());
  assert(ncoord == prev_step.size());
  assert(ncoord <= force.size());
  assert(ncoord_tot == force.size());

  int nthread = 512;
  int nblock = (step.size() - 1)/nthread + 1;

  double dtsq = timestep_akma*timestep_akma;

  calc_step_kernel<<< nblock, nthread, 0, stream >>>
    (ncoord, force.stride(), dtsq, (double *)force.xyz(), 
     prev_step.x(), prev_step.y(), prev_step.z(), mass,
     step.x(), step.y(), step.z());
  cudaCheck(cudaGetLastError());
}

//
// Calculate forces
//
void CudaLeapfrogIntegrator::calc_force(const bool calc_energy, const bool calc_virial) {
  if (forcefield != NULL) {
    CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
    p->calc(calc_energy, calc_virial, coord, prev_step, force, stream);
    // Get (possibly) new ncoord and ncoord_tot
    // NOTE: these change with neighborlist update
    ncoord = prev_step.size();
    ncoord_tot = coord.size();
    // Re-allocate rest of the arrays if necessary
    prev_coord.realloc(ncoord_tot);
    step.realloc(ncoord);
    reallocate<float>(&mass, &mass_len, ncoord);
  }
}

void CudaLeapfrogIntegrator::post_calc_force() {
  if (forcefield != NULL) {
    CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
    p->post_calc(global_mass, mass, holoconst, stream);
  }
}

void CudaLeapfrogIntegrator::stop_calc_force() {
  if (forcefield != NULL) {
    CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
    p->stop_calc(stream);
  }
}

//
// Calculate temperature
//
void CudaLeapfrogIntegrator::calc_temperature() {
  assert(ncoord == step.size());
  assert(ncoord == prev_step.size());

  // Clear kinetic energy accumulator
  h_CudaLeapfrogIntegrator_storage->kine = 0.0;
  cudaCheck(cudaMemcpyToSymbolAsync(d_CudaLeapfrogIntegrator_storage,
				    h_CudaLeapfrogIntegrator_storage,
				    sizeof(CudaLeapfrogIntegrator_storage_t),
				    0, cudaMemcpyHostToDevice, stream));
  // Calculate kinetic energy
  int nthread = 512;
  int nblock = (ncoord - 1)/nthread + 1;
  int shmem_size = nthread*sizeof(double);
  double fac = 0.5/timestep_akma;
  calc_kine_kernel<<< nblock, nthread, shmem_size, stream >>>
    (ncoord, fac, mass, 
     prev_step.x(), prev_step.y(), prev_step.z(),
     step.x(), step.y(), step.z());
  cudaCheck(cudaGetLastError());
  // Retrieve result
  cudaCheck(cudaStreamSynchronize(stream));
  cudaCheck(cudaMemcpyFromSymbol(h_CudaLeapfrogIntegrator_storage,
				 d_CudaLeapfrogIntegrator_storage,
				 sizeof(CudaLeapfrogIntegrator_storage_t),
				 0, cudaMemcpyDeviceToHost));
  //std::cout << "kinetic energy = " << 0.5*h_CudaLeapfrogIntegrator_storage->kine << std::endl;
}

//
// Do holonomic constraints
//
// Compute x' = x + dx
// Send x' to left
// Compute holoconst(x,x'), this gives us x'->x''.
// Define x'' = x + dx'
// Send x'' to right
// Compute dx' = x'' - x
//
void CudaLeapfrogIntegrator::do_holoconst() {
  if (holoconst != NULL) {
    // prev_coord = coord + step
    // NOTE: add_coord and sub_coord only operate on the homebox coordinates (i < ncoord)
    add_coord(coord, step, prev_coord);

    // Send prev_coord to left
    if (forcefield != NULL) {
      CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
      p->constComm(-1, prev_coord, stream);
    }
    
    // holonomic constraint, result in prev_coord
    holoconst->apply(coord, prev_coord, stream);

    // Send prev_coord to right
    if (forcefield != NULL) {
      CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
      p->constComm(+1, prev_coord, stream);
    }

    // step = -coord + prev_coord
    sub_coord(prev_coord, coord, step);
  }
}

//
// Calculates: a = b + c
//
void CudaLeapfrogIntegrator::add_coord(cudaXYZ<double> &b, cudaXYZ<double> &c,
				       cudaXYZ<double> &a) {
  assert(ncoord <= a.size());
  assert(ncoord <= b.size());
  assert(ncoord <= c.size());

  int nthread = 512;
  int nblock = (ncoord - 1)/nthread + 1;

  add_coord_kernel<<< nblock, nthread, 0, stream >>>
    (ncoord, b.x(), b.y(), b.z(), c.x(), c.y(), c.z(), a.x(), a.y(), a.z() );

  cudaCheck(cudaGetLastError());
}

//
// Calculates: a = b - c
//
void CudaLeapfrogIntegrator::sub_coord(cudaXYZ<double> &b, cudaXYZ<double> &c,
				       cudaXYZ<double> &a) {
  assert(ncoord <= a.size());
  assert(ncoord <= b.size());
  assert(ncoord <= c.size());

  int nthread = 512;
  int nblock = (ncoord - 1)/nthread + 1;

  sub_coord_kernel<<< nblock, nthread, 0, stream >>>
    (ncoord, b.x(), b.y(), b.z(), c.x(), c.y(), c.z(), a.x(), a.y(), a.z());

  cudaCheck(cudaGetLastError());
}

//
// Do constant pressure
//
void CudaLeapfrogIntegrator::do_pressure() {
}

//
// Returns true if constant pressure is ON
//
bool CudaLeapfrogIntegrator::const_pressure() {
  return false;
}

//
// Do constant temperature
//
void CudaLeapfrogIntegrator::do_temperature() {
}

//
// Print energy & other info on screen
//
void CudaLeapfrogIntegrator::do_print_energy(int step) {
  if (forcefield != NULL) {
    CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
    p->print_energy_virial(step, h_CudaLeapfrogIntegrator_storage->kine);
  }
}

//
// Get coordinates to host memory
//
void CudaLeapfrogIntegrator::get_restart_data(double *x, double *y, double *z,
					      double *dx, double *dy, double *dz,
					      double *fx, double *fy, double *fz) {
  if (forcefield != NULL) {
    CudaForcefield *p = static_cast<CudaForcefield*>(forcefield);
    p->get_restart_data(coord, step, force, x, y, z, dx, dy, dz, fx, fy, fz);
  }
}
