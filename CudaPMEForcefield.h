#ifndef CUDAPMEFORCEFIELD_H
#define CUDAPMEFORCEFIELD_H
#include "CudaForcefield.h"
#include "cudaXYZ.h"
#include "XYZQ.h"
#include "NeighborList.h"
#include "DirectForce.h"
#include "BondedForce.h"
#include "Grid.h"
#include "CudaDomdec.h"
#include "CudaDomdecBonded.h"

class CudaPMEForcefield : public CudaForcefield {

private:

  // Reference coordinates for neighborlist building
  cudaXYZ<double> ref_coord;

  // flag for checking heuristic neighborlist update
  int *d_heuristic_flag;
  int *h_heuristic_flag;

  // Cut-offs:
  double roff, ron;
  
  // Global charge table
  float *q;

  // Coordinates in XYZQ format
  XYZQ xyzq;

  // Coordinates in XYZQ format
  XYZQ xyzq_copy;

  // --------------
  // Neighbor list
  // --------------
  NeighborList<32> *nlist;

  // ------------------------
  // Direct non-bonded force
  // ------------------------
  DirectForce<long long int, float> dir;

  // Global vdw types
  int *glo_vdwtype;

  // -------------
  // Bonded force
  // -------------
  
  BondedForce<long long int, float> bonded;

  // -----------------
  // Reciprocal force
  // -----------------
  double kappa;
  Grid<int, float, float2> *grid;
  Force<float> recip_force;

  // ---------------------
  // Domain decomposition
  // ---------------------
  CudaDomdec *domdec;
  CudaDomdecBonded *domdec_bonded;

  // Host version of loc2glo
  int h_loc2glo_len;
  int *h_loc2glo;

  // ---------------------
  // Energies and virials
  // ---------------------
  double energy_bond;
  double energy_ureyb;
  double energy_angle;
  double energy_dihe;
  double energy_imdihe;
  double energy_cmap;
  double sforcex[27];
  double sforcey[27];
  double sforcez[27];

  double energy_vdw;
  double energy_elec;
  double energy_excl;
  double energy_ewksum;
  double energy_ewself;
  double vir[9];

  bool heuristic_check(const cudaXYZ<double> *coord);

  void setup_direct_nonbonded(const double roff, const double ron,
			      const double kappa, const double e14fac,
			      const int vdw_model, const int elec_model,
			      const int nvdwparam, const float *h_vdwparam,
			      const float *h_vdwparam14, const int *h_glo_vdwtype);

  void setup_recip_nonbonded(const double kappa,
			     const int nfftx, const int nffty, const int nfftz,
			     const int order);

public:

  CudaPMEForcefield(CudaDomdec *domdec, CudaDomdecBonded *domdec_bonded,
		    NeighborList<32> *nlist,
		    const int nbondcoef, const float2 *h_bondcoef,
		    const int nureybcoef, const float2 *h_ureybcoef,
		    const int nanglecoef, const float2 *h_anglecoef,
		    const int ndihecoef, const float4 *h_dihecoef,
		    const int nimdihecoef, const float4 *h_imdihecoef,
		    const int ncmapcoef, const float2 *h_cmapcoef,
		    const double roff, const double ron,
		    const double kappa, const double e14fac,
		    const int vdw_model, const int elec_model,
		    const int nvdwparam, const float *h_vdwparam,
		    const float *h_vdwparam14,
		    const int* h_glo_vdwtype, const float *h_q,
		    const int nfftx, const int nffty, const int nfftz,
		    const int order);
  ~CudaPMEForcefield();

  void calc(cudaXYZ<double> *coord, cudaXYZ<double> *prev_step, float *mass,
	    const bool calc_energy, const bool calc_virial,
	    Force<long long int> *force);

  void init_coord(cudaXYZ<double> *coord);

  void get_restart_data(hostXYZ<double> *h_coord, hostXYZ<double> *h_step, hostXYZ<double> *h_force,
			double *x, double *y, double *z, double *dx, double *dy, double *dz,
			double *fx, double *fy, double *fz);
  
  void print_energy_virial(int step);
};

#endif // CUDAPMEFORCEFIELD_H
