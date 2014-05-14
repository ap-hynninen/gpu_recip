
#include "gpu_utils.h"
#include "CudaDomdec.h"

//
// Builds homezone
//
__global__ void build_homezone_kernel(const int ncoord, int* __restrict__ loc2glo) {
  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  if (i < ncoord) {
    loc2glo[i] = i;
  }
}

//
// Calculates (x, y, z) shift
// (x0, y0, z0) = fractional origin
//
__global__ void calc_xyz_shift(const int ncoord, const int stride, const double* __restrict__ coord,
			       const double x0, const double y0, const double z0,
			       const double inv_boxx, const double inv_boxy, const double inv_boxz,
			       float3* __restrict__ xyz_shift) {
  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  if (i < ncoord) {
    double x = coord[i]*inv_boxx;
    double y = coord[i+stride]*inv_boxy;
    double z = coord[i+stride*2]*inv_boxz;
    float3 shift;
    shift.x = ceilf(x0 - x);
    shift.y = ceilf(y0 - y);
    shift.z = ceilf(z0 - z);
    xyz_shift[i] = shift;
  }
}

//#############################################################################################
//#############################################################################################
//#############################################################################################

//
// Class creator
//
CudaDomdec::CudaDomdec(int ncoord_tot, double boxx, double boxy, double boxz, double rnl,
		       int nx, int ny, int nz, int mynode) {
  this->ncoord_tot = ncoord_tot;
  this->boxx = boxx;
  this->boxy = boxy;
  this->boxz = boxz;
  this->rnl = rnl;
  this->nx = nx;
  this->ny = ny;
  this->nz = nz;
  this->numnode = nx*ny*nz;
  this->mynode = mynode;
  
  loc2glo_len = 0;
  loc2glo = NULL;

  xyz_shift_len = 0;
  xyz_shift = NULL;
}

//
// Class destructor
//
CudaDomdec::~CudaDomdec() {
  if (loc2glo != NULL) deallocate<int>(&loc2glo);
  if (xyz_shift != NULL) deallocate<float3>(&xyz_shift);
}

//
// Builds coordinate distribution across all nodes
// NOTE: Here all nodes have all coordinates
//
void CudaDomdec::build_homezone(cudaXYZ<double> *coord, cudaStream_t stream) {
  if (numnode == 1) {
    zone_natom[0] = coord->n;
    for (int i=1;i < 8;i++) zone_natom[i] = 0;

    reallocate<int>(&loc2glo, &loc2glo_len, coord->n);

    int nthread = 512;
    int nblock = (coord->n - 1)/nthread + 1;
    int shmem_size = 0;
    build_homezone_kernel<<< nblock, nthread, shmem_size, stream >>>
      (coord->n, loc2glo);
    cudaCheck(cudaGetLastError());
  } else {
    std::cerr << "CudaDomdec::build_homezone, numnode > 1 not implemented" << std::endl;
    exit(1);
  }
}

//
// Update coordinate distribution across all nodes
//
void CudaDomdec::update_homezone(cudaXYZ<double> *coord, cudaStream_t stream) {
  /*
  int *h_loc2glo = new int[23558];
  copy_DtoH_sync<int>(loc2glo, h_loc2glo, 23558);
  for (int i=0;i < 10;i++)
    std::cerr << h_loc2glo[i] << std::endl;
  delete [] h_loc2glo;
  */
}

//
// Communicate coordinates
//
void CudaDomdec::comm_coord(cudaXYZ<double> *coord, bool update, cudaStream_t stream) {

  // Calculate zone_patom
  zone_patom[0] = zone_natom[0];
  for (int i=1;i < 8;i++) {
    zone_patom[i] = zone_patom[i-1] + zone_natom[i];
  }

  // Calculate xyz_shift
  if (update) {
    double x0 = 0.0;
    double y0 = 0.0;
    double z0 = 0.0;
    double inv_boxx = 1.0/boxx;
    double inv_boxy = 1.0/boxy;
    double inv_boxz = 1.0/boxz;

    float fac = (numnode > 1) ? 1.2f : 1.0f;
    reallocate<float3>(&xyz_shift, &xyz_shift_len, zone_patom[7], fac);
    
    int nthread = 512;
    int nblock = (zone_patom[7] - 1)/nthread + 1;
    calc_xyz_shift<<< nblock, nthread, 0, stream >>>
      (zone_patom[7], coord->stride, coord->data,
       x0, y0, z0, inv_boxx, inv_boxy, inv_boxz, xyz_shift);
    cudaCheck(cudaGetLastError());
  }

}

//
// Communicate forces
//
void CudaDomdec::comm_force(Force<long long int> *force, cudaStream_t stream) {
}

