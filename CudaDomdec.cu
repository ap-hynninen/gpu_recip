#include <cassert>
#include "gpu_utils.h"
#include "CudaDomdec.h"

//
// Calculates (x, y, z) shift
// (x0, y0, z0) = fractional origin
// ncoord_home = number of atoms in the home box
//
__global__ void calc_xyz_shift(const int ncoord, const int ncoord_home,
			       const double* __restrict__ x,
			       const double* __restrict__ y,
			       const double* __restrict__ z,
			       const double inv_boxx, const double inv_boxy, const double inv_boxz,
			       const int* __restrict__ loc2glo,
			       const double lox, const double hix,
			       const double loy, const double hiy,
			       const double loz, const double hiz,
			       float3* __restrict__ xyz_shift,
			       char* __restrict__ coordLoc,
			       int* __restrict__ error_flag) {
  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  int error = 0;
  if (i < ncoord) {
    double xi = x[i]*inv_boxx + 0.5 - lox;
    double yi = y[i]*inv_boxy + 0.5 - loy;
    double zi = z[i]*inv_boxz + 0.5 - loz;
    double shx = -floor(xi);
    double shy = -floor(yi);
    double shz = -floor(zi);
    float3 shift;
    shift.x = (float)shx;
    shift.y = (float)shy;
    shift.z = (float)shz;
    xyz_shift[i] = shift;
    double xf = xi + shx;
    double yf = yi + shy;
    double zf = zi + shz;
    // (xf, yf, zf) is in range (0...1)
    int iglo = loc2glo[i];
    //int loca = (xf >= 0.0 && xf < hix) | ((yf >= 0.0 && yf < hiy) << 1) | 
    //  ((zf >= 0.0 && zf < hiz) << 2);
    int locx = (xf >= 0.0) | ((xf < hix) << 1);
    int locy = (yf >= 0.0) | ((yf < hiy) << 1);
    int locz = (zf >= 0.0) | ((zf < hiz) << 1);
    //if (loca == 0) error = true;
    // "Left side" -error
    if (locx == 2 || locy == 2 || locz == 2) error = 1;
    // "None of the directions in range" -error
    if (locx != 3 && locy != 3 && locz != 3) error = 2;
    int loca = (locx | (locy << 2) | (locz << 4));
    // "Inconsistent home box assignment" -error
    if ((loca == 63) ^ (i < ncoord_home)) error = 3;
    coordLoc[iglo] = (char)loca;
  }
  if (error != 0) {
    //printf("%d %lf %lf %lf\n",i,x[i],y[i],z[i]);
    *error_flag = error;
  }
}

//
// Re-order coordinates
// x_dst[i] = x_src[ind_sorted[i]];
//
__global__ void reorder_coord_kernel(const int ncoord,
				     const int* __restrict__ ind_sorted,
				     const double* __restrict__ x_src,
				     const double* __restrict__ y_src,
				     const double* __restrict__ z_src,
				     double* __restrict__ x_dst,
				     double* __restrict__ y_dst,
				     double* __restrict__ z_dst) {
  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  if (i < ncoord) {
    int j = ind_sorted[i];
    x_dst[i] = x_src[j];
    y_dst[i] = y_src[j];
    z_dst[i] = z_src[j];
  }
}

//
// Re-order xyz_shift
// xyz_shift_out[i] = xyz_shift_in[ind_sorted[i]];
//
__global__ void reorder_xyz_shift_kernel(const int ncoord,
					 const int* __restrict__ ind_sorted,
					 const float3* __restrict__ xyz_shift_in,
					 float3* __restrict__ xyz_shift_out) {
  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  if (i < ncoord) {
    int j = ind_sorted[i];
    xyz_shift_out[i] = xyz_shift_in[j];
  }
}

/*
//
// Re-order mass
//
__global__ void reorder_mass_kernel(const int ncoord,
				    const int* __restrict__ ind_sorted,
				    const float* __restrict__ mass_in,
				    float* __restrict__ mass_out) {
  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  if (i < ncoord) {
    int j = ind_sorted[i];
    mass_out[i] = mass_in[j];
  }
}
*/

//#############################################################################################
//#############################################################################################
//#############################################################################################

//
// Class creator
//
CudaDomdec::CudaDomdec(int ncoord_glo, double boxx, double boxy, double boxz, double rnl,
		       int nx, int ny, int nz, int mynode, CudaMPI& cudaMPI) :
  cudaMPI(cudaMPI),
  Domdec(ncoord_glo, boxx, boxy, boxz, rnl, nx, ny, nz, mynode, cudaMPI.get_comm()),
  homezone(*this, cudaMPI), D2Dcomm(*this, cudaMPI) {

  xyz_shift0_len = 0;
  xyz_shift0 = NULL;

  xyz_shift1_len = 0;
  xyz_shift1 = NULL;

  mass_tmp_len = 0;
  mass_tmp = NULL;

  allocate<char>(&coordLoc, ncoord_glo);
  clear_gpu_array_sync<char>(coordLoc, ncoord_glo);

  allocate<int>(&error_flag, 1);
  allocate_host<int>(&h_error_flag, 1);

  constComm = NULL;
}

//
// Class destructor
//
CudaDomdec::~CudaDomdec() {
  deallocate<char>(&coordLoc);
  deallocate<int>(&error_flag);
  deallocate_host<int>(&h_error_flag);
  if (xyz_shift0 != NULL) deallocate<float3>(&xyz_shift0);
  if (xyz_shift1 != NULL) deallocate<float3>(&xyz_shift1);
  if (mass_tmp != NULL) deallocate<float>(&mass_tmp);
  if (constComm != NULL) delete constComm;
}

//
// Setup constraint communication
//
void CudaDomdec::constCommSetup(const int* neighPos, int* coordInd, const int* glo2loc,
				cudaStream_t stream) {
  if (numnode > 1) {
    if (constComm == NULL) {
      constComm = new CudaDomdecConstComm(*this, cudaMPI);
    }
    constComm->setup(neighPos, coordInd, glo2loc, stream);
  }
}

//
// Communicate constraint coordinates
//
void CudaDomdec::constCommDo(const int dir, cudaXYZ<double>& coord, cudaStream_t stream) {
  assert(dir == -1 || dir == 1);
  if (numnode > 1) {
    assert(constComm != NULL);
    constComm->communicate(dir, coord, stream);
  }  
}

//
// Builds coordinate distribution across all nodes
// NOTE: Here all nodes have all coordinates.
// NOTE: Used only in the beginning of dynamics
//
void CudaDomdec::build_homezone(hostXYZ<double>& coord) {
  this->clear_zone_ncoord();
  this->set_zone_ncoord(I, homezone.build(coord));
}

//
// Update coordinate distribution across all nodes
// Update is done according to coord, coord2 is a hangaround
// NOTE: Used during dynamics
//
void CudaDomdec::update_homezone(cudaXYZ<double>& coord, cudaXYZ<double>& coord2, cudaStream_t stream) {
  if (numnode > 1) {
    // Read value of ncoord before it is reset on the next line
    int ncoord = this->get_ncoord();
    this->clear_zone_ncoord();
    this->set_zone_ncoord(I, homezone.update(ncoord, coord, coord2, stream));
  }
}

//
// Communicate coordinates
//
void CudaDomdec::comm_coord(cudaXYZ<double>& coord, const bool update, cudaStream_t stream) {

  D2Dcomm.comm_coord(coord, homezone.get_loc2glo(), update, stream);

  // Calculate xyz_shift
  if (update) {
    int nthread, nblock;

    // Re-allocate (xyz_shift0, xyz_shift1)
    float fac = (numnode > 1) ? 1.2f : 1.0f;
    reallocate<float3>(&xyz_shift0, &xyz_shift0_len, this->get_ncoord_tot(), fac);
    reallocate<float3>(&xyz_shift1, &xyz_shift1_len, this->get_ncoord_tot(), fac);    

    clear_gpu_array<char>(coordLoc, ncoord_glo, stream);
    clear_gpu_array<int>(error_flag, 1, stream);

    nthread = 512;
    nblock = (this->get_ncoord_tot() - 1)/nthread + 1;
    calc_xyz_shift<<< nblock, nthread, 0, stream >>>
      (this->get_ncoord_tot(), this->get_ncoord(), coord.x(), coord.y(), coord.z(),
       this->get_inv_boxx(), this->get_inv_boxy(), this->get_inv_boxz(),
       this->get_loc2glo_ptr(),
       this->get_lo_bx(), this->get_hi_bx()-this->get_lo_bx(),
       this->get_lo_by(), this->get_hi_by()-this->get_lo_by(),
       this->get_lo_bz(), this->get_hi_bz()-this->get_lo_bz(),
       xyz_shift0, coordLoc, error_flag);
    cudaCheck(cudaGetLastError());

    copy_DtoH<int>(error_flag, h_error_flag, 1, stream);
    cudaCheck(cudaStreamSynchronize(stream));
    
    if (*h_error_flag == 1) {
      std::cout << "CudaDomdec::comm_coord, calc_xyz_shift Coordinate-Left-Side error" << std::endl;
      exit(1);
    } else if (*h_error_flag == 2) {
      std::cout << "CudaDomdec::comm_coord, calc_xyz_shift None-of-the-components-in-range error" << std::endl;
      exit(1);      
    } else if (*h_error_flag == 3) {
      std::cout << "CudaDomdec::comm_coord, calc_xyz_shift Home-box-coordinates-inconsisten error" << std::endl;
      exit(1);      
    }
  }

}

//
// Update communication (we're updating the local receive indices)
//
void CudaDomdec::comm_update(int* glo2loc, cudaStream_t stream) {
  D2Dcomm.comm_update(glo2loc);
}

//
// Communicate forces
//
void CudaDomdec::comm_force(Force<long long int>& force, cudaStream_t stream) {
  D2Dcomm.comm_force(force, stream);
}

//
// Test comm_coord method
//
void CudaDomdec::test_comm_coord(const int* glo2loc, cudaXYZ<double>& coord) {
  cudaCheck(cudaDeviceSynchronize());
  D2Dcomm.test_comm_coord(glo2loc, coord);
}

//
// Re-order coordinates using ind_sorted: coord_src => coord_dst
//
void CudaDomdec::reorder_coord(const int n, cudaXYZ<double>& coord_src, cudaXYZ<double>& coord_dst,
			       const int* ind_sorted, cudaStream_t stream) {
  assert(n <= coord_src.size());
  assert(n <= coord_dst.size());

  // Reorder: coord_src => coord_dst
  int nthread = 512;
  int nblock = (n - 1)/nthread + 1;
  reorder_coord_kernel<<< nblock, nthread, 0, stream >>>
    (n, ind_sorted,
     coord_src.x(), coord_src.y(), coord_src.z(),
     coord_dst.x(), coord_dst.y(), coord_dst.z());
  cudaCheck(cudaGetLastError());

  // Copy: coord_src = coord_dst
  coord_src.set_data(n, coord_dst, stream);
}

//
// Re-order xyz_shift
//
void CudaDomdec::reorder_xyz_shift(const int* ind_sorted, cudaStream_t stream) {

  int nthread = 512;
  int nblock = (this->get_ncoord_tot() - 1)/nthread + 1;
  reorder_xyz_shift_kernel<<< nblock, nthread, 0, stream >>>
    (this->get_ncoord_tot(), ind_sorted, xyz_shift0, xyz_shift1);
  cudaCheck(cudaGetLastError());

  float3 *p = xyz_shift0;
  xyz_shift0 = xyz_shift1;
  xyz_shift1 = p;

  int t = xyz_shift0_len;
  xyz_shift0_len = xyz_shift1_len;
  xyz_shift1_len = t;
}

/*
//
// Re-order mass
//
void CudaDomdec::reorder_mass(float *mass, const int* ind_sorted, cudaStream_t stream) {

  float fac = (numnode > 1) ? 1.2f : 1.0f;
  reallocate<float>(&mass_tmp, &mass_tmp_len, this->get_ncoord_tot(), fac);

  int nthread = 512;
  int nblock = (this->get_ncoord_tot() - 1)/nthread + 1;
  reorder_mass_kernel<<< nblock, nthread, 0, stream >>>
    (this->get_ncoord_tot(), ind_sorted, mass, mass_tmp);
  cudaCheck(cudaGetLastError());

  copy_DtoD<float>(mass_tmp, mass, this->get_ncoord_tot(), stream);
}
*/

