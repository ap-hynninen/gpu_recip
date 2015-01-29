#include <cuda.h>
#include "cuda_utils.h"
#include "Bonded_struct.h"
#include "CudaNeighborListBuild.h"
#include "CudaDirectForceTypes.h"
#include "CudaBlock.h"
#include "gpu_utils.h"

#define USE_TEXTURES true
#undef USE_TEXTURE_OBJECTS

// Settings for direct computation in device memory
__constant__ DirectSettings_t d_setup;

// Energy and virial in device memory
//static __device__ DirectEnergyVirial_t d_energy_virial;

#ifndef USE_TEXTURE_OBJECTS
// VdW parameter texture reference
texture<float2, 1, cudaReadModeElementType> vdwparam_texref;
bool vdwparam_texref_bound = false;
texture<float2, 1, cudaReadModeElementType> vdwparam14_texref;
bool vdwparam14_texref_bound = false;
texture<float, 1, cudaReadModeElementType> blockParamTexRef;
bool blockParamTexRefBound = false;
texture<float2, 1, cudaReadModeElementType>* get_vdwparam_texref() {return &vdwparam_texref;}
texture<float2, 1, cudaReadModeElementType>* get_vdwparam14_texref() {return &vdwparam14_texref;}
texture<float, 1, cudaReadModeElementType>* getBlockParamTexRef() {return &blockParamTexRef;}
bool get_vdwparam_texref_bound() {return vdwparam_texref_bound;}
bool get_vdwparam14_texref_bound() {return vdwparam14_texref_bound;}
bool getBlockParamTexRefBound() {return blockParamTexRefBound;}
void set_vdwparam_texref_bound(const bool val) {vdwparam_texref_bound=val;}
void set_vdwparam14_texref_bound(const bool val) {vdwparam14_texref_bound=val;}
void setBlockParamTexRefBound(const bool val) {blockParamTexRefBound=val;}
#endif

static __constant__ const float ccelec = 332.0716f;
const int tilesize = 32;

//
// Nonbonded virial
//
template <typename AT, typename CT>
__global__ void calc_virial_kernel(const int ncoord, const float4* __restrict__ xyzq,
				   const int stride, DirectEnergyVirial_t* __restrict__ energy_virial,
				   const AT* __restrict__ force) {
  // Shared memory:
  // Required memory
  // blockDim.x*9*sizeof(double) for __CUDA_ARCH__ < 300
  // blockDim.x*9*sizeof(double)/warpsize for __CUDA_ARCH__ >= 300
  extern __shared__ volatile double sh_vir[];

  const int i = threadIdx.x + blockIdx.x*blockDim.x;
  const int ish = i - ncoord;

  double vir[9];
  if (i < ncoord) {
    float4 xyzqi = xyzq[i];
    double x = (double)xyzqi.x;
    double y = (double)xyzqi.y;
    double z = (double)xyzqi.z;
    double fx = ((double)force[i])*INV_FORCE_SCALE;
    double fy = ((double)force[i+stride])*INV_FORCE_SCALE;
    double fz = ((double)force[i+stride*2])*INV_FORCE_SCALE;
    vir[0] = x*fx;
    vir[1] = x*fy;
    vir[2] = x*fz;
    vir[3] = y*fx;
    vir[4] = y*fy;
    vir[5] = y*fz;
    vir[6] = z*fx;
    vir[7] = z*fy;
    vir[8] = z*fz;
  } else if (ish >= 0 && ish <= 26) {
    double sforcex = energy_virial->sforcex[ish];
    double sforcey = energy_virial->sforcey[ish];
    double sforcez = energy_virial->sforcez[ish];
    int ish_tmp = ish;
    double shz = (double)((ish_tmp/9 - 1)*d_setup.boxz);
    ish_tmp -= (ish_tmp/9)*9;
    double shy = (double)((ish_tmp/3 - 1)*d_setup.boxy);
    ish_tmp -= (ish_tmp/3)*3;
    double shx = (double)((ish_tmp - 1)*d_setup.boxx);
    vir[0] = shx*sforcex;
    vir[1] = shx*sforcey;
    vir[2] = shx*sforcez;
    vir[3] = shy*sforcex;
    vir[4] = shy*sforcey;
    vir[5] = shy*sforcez;
    vir[6] = shz*sforcex;
    vir[7] = shz*sforcey;
    vir[8] = shz*sforcez;
  } else {
#pragma unroll
    for (int k=0;k < 9;k++)
      vir[k] = 0.0;
  }

  // Reduce
  //#if __CUDA_ARCH__ < 300
  // 0-2
#pragma unroll
  for (int k=0;k < 3;k++)
    sh_vir[threadIdx.x + k*blockDim.x] = vir[k];
  __syncthreads();
  for (int i=1;i < blockDim.x;i *= 2) {
    int pos = threadIdx.x + i;
    double vir_val[3];
#pragma unroll
    for (int k=0;k < 3;k++)
      vir_val[k] = (pos < blockDim.x) ? sh_vir[pos + k*blockDim.x] : 0.0;
    __syncthreads();
#pragma unroll
    for (int k=0;k < 3;k++)
      sh_vir[threadIdx.x + k*blockDim.x] += vir_val[k];
    __syncthreads();
  }
  if (threadIdx.x == 0) {
#pragma unroll
    for (int k=0;k < 3;k++)
      atomicAdd(&energy_virial->vir[k], -sh_vir[k*blockDim.x]);
  }

  // 3-5
#pragma unroll
  for (int k=0;k < 3;k++)
    sh_vir[threadIdx.x + k*blockDim.x] = vir[k+3];
  __syncthreads();
  for (int i=1;i < blockDim.x;i *= 2) {
    int pos = threadIdx.x + i;
    double vir_val[3];
#pragma unroll
    for (int k=0;k < 3;k++)
      vir_val[k] = (pos < blockDim.x) ? sh_vir[pos + k*blockDim.x] : 0.0;
    __syncthreads();
#pragma unroll
    for (int k=0;k < 3;k++)
      sh_vir[threadIdx.x + k*blockDim.x] += vir_val[k];
    __syncthreads();
  }
  if (threadIdx.x == 0) {
#pragma unroll
    for (int k=0;k < 3;k++)
      atomicAdd(&energy_virial->vir[k+3], -sh_vir[k*blockDim.x]);
  }

  // 6-8
#pragma unroll
  for (int k=0;k < 3;k++)
    sh_vir[threadIdx.x + k*blockDim.x] = vir[k+6];
  __syncthreads();
  for (int i=1;i < blockDim.x;i *= 2) {
    int pos = threadIdx.x + i;
    double vir_val[3];
#pragma unroll
    for (int k=0;k < 3;k++)
      vir_val[k] = (pos < blockDim.x) ? sh_vir[pos + k*blockDim.x] : 0.0;
    __syncthreads();
#pragma unroll
    for (int k=0;k < 3;k++)
      sh_vir[threadIdx.x + k*blockDim.x] += vir_val[k];
    __syncthreads();
  }
  if (threadIdx.x == 0) {
#pragma unroll
    for (int k=0;k < 3;k++)
      atomicAdd(&energy_virial->vir[k+6], -sh_vir[k*blockDim.x]);
  }

}

//
// Calculates VdW pair force & energy
// NOTE: force (fij_vdw) is r*dU/dr
//
template <int vdw_model, bool calc_energy>
__forceinline__ __device__
float pair_vdw_force(const float r2, const float r, const float rinv, const float rinv2,
		     const float c6, const float c12,float &pot_vdw) {

  float fij_vdw;

  if (vdw_model == VDW_VSH) {
    float r6 = r2*r2*r2;
    float rinv6 = rinv2*rinv2*rinv2;
    float rinv12 = rinv6*rinv6;
    if (calc_energy) {
      const float one_twelve = 0.0833333333333333f;
      const float one_six = 0.166666666666667f;
      pot_vdw = c12*one_twelve*(rinv12 + 2.0f*r6*d_setup.roffinv18 - 3.0f*d_setup.roffinv12)-
	c6*one_six*(rinv6 + r6*d_setup.roffinv12 - 2.0f*d_setup.roffinv6);
    }
	  
    fij_vdw = c6*(rinv6 - r6*d_setup.roffinv12) - c12*(rinv12 + r6*d_setup.roffinv18);
  } else if (vdw_model == VDW_VSW) {
    float roff2_r2_sq = d_setup.roff2 - r2;
    roff2_r2_sq *= roff2_r2_sq;
    float sw = (r2 <= d_setup.ron2) ? 1.0f : 
      roff2_r2_sq*(d_setup.roff2 + 2.0f*r2 - 3.0f*d_setup.ron2)*d_setup.inv_roff2_ron2;
    // dsw_6 = dsw/6.0
    float dsw_6 = (r2 <= d_setup.ron2) ? 0.0f : 
      (d_setup.roff2-r2)*(d_setup.ron2-r2)*d_setup.inv_roff2_ron2;
    float rinv4 = rinv2*rinv2;
    float rinv6 = rinv4*rinv2;
    fij_vdw = rinv4*( c12*rinv6*(dsw_6 - sw*rinv2) - c6*(2.0f*dsw_6 - sw*rinv2) );
    if (calc_energy) {
      const float one_twelve = 0.0833333333333333f;
      const float one_six = 0.166666666666667f;
      pot_vdw = sw*rinv6*(one_twelve*c12*rinv6 - one_six*c6);
    }
  } else if (vdw_model == VDW_CUT) {
    float rinv6 = rinv2*rinv2*rinv2;
    if (calc_energy) {
      const float one_twelve = 0.0833333333333333f;
      const float one_six = 0.166666666666667f;
      float rinv12 = rinv6*rinv6;
      pot_vdw = c12*one_twelve*rinv12 - c6*one_six*rinv6;
      fij_vdw = c6*rinv6 - c12*rinv12;
    } else {
      fij_vdw = c6*rinv6 - c12*rinv6*rinv6;
    }
  } else if (vdw_model == VDW_VFSW) {
    float rinv3 = rinv*rinv2;
    float rinv6 = rinv3*rinv3;
    float A6 = (r2 > d_setup.ron2) ? d_setup.k6 : 1.0f;
    float B6 = (r2 > d_setup.ron2) ? d_setup.roffinv3  : 0.0f;
    float A12 = (r2 > d_setup.ron2) ? d_setup.k12 : 1.0f;
    float B12 = (r2 > d_setup.ron2) ? d_setup.roffinv6 : 0.0f;
    fij_vdw = c6*A6*(rinv3 - B6)*rinv3 - c12*A12*(rinv6 - B12)*rinv6;
    if (calc_energy) {
      const float one_twelve = 0.0833333333333333f;
      const float one_six = 0.166666666666667f;
      float C6  = (r2 > d_setup.ron2) ? 0.0f : d_setup.dv6;
      float C12 = (r2 > d_setup.ron2) ? 0.0f : d_setup.dv12;

      float rinv3_B6_sq = rinv3 - B6;
      rinv3_B6_sq *= rinv3_B6_sq;

      float rinv6_B12_sq = rinv6 - B12;
      rinv6_B12_sq *= rinv6_B12_sq;

      pot_vdw = one_twelve*c12*(A12*rinv6_B12_sq + C12) - one_six*c6*(A6*rinv3_B6_sq + C6);
    }
  } else if (vdw_model == VDW_VGSH) {
    float rinv3 = rinv*rinv2;
    float rinv6 = rinv3*rinv3;
    float rinv12 = rinv6*rinv6;
    float r_ron = (r2 > d_setup.ron2) ? (r-d_setup.ron) : 0.0f;
    float r_ron2_r = r_ron*r_ron*r;

    fij_vdw = c6*(rinv6 + (d_setup.ga6 + d_setup.gb6*r_ron)*r_ron2_r ) -
      c12*(rinv12 + (d_setup.ga12 + d_setup.gb12*r_ron)*r_ron2_r );

    if (calc_energy) {
      const float one_twelve = 0.0833333333333333f;
      const float one_six = 0.166666666666667f;
      const float one_third = (float)(1.0/3.0);
      float r_ron3 = r_ron*r_ron*r_ron;
      pot_vdw = c6*(-one_six*rinv6 + (one_third*d_setup.ga6 + 0.25f*d_setup.gb6*r_ron)*r_ron3 
		    + d_setup.gc6) +
	c12*(one_twelve*rinv12 - (one_third*d_setup.ga12 + 0.25f*d_setup.gb12*r_ron)*r_ron3 
	     - d_setup.gc12);
    }
    /*
    if (r > ctonnb) then
             d = 6.0f/r**7 + GA6*(r-ctonnb)**2 + GB6*(r-ctonnb)**3
             d = -(12.0f/r**13 + GA12*(r-ctonnb)**2 + GB12*(r-ctonnb)**3)

             e = -r**(-6) + (GA6*(r-ctonnb)**3)/3.0 + (GB6*(r-ctonnb)**4)/4.0 + GC6
             e = r**(-12) - (GA12*(r-ctonnb)**3)/3.0 - (GB12*(r-ctonnb)**4)/4.0 - GC12

          else
             d = 6.0f/r**7
             d = -12.0f/r**13

             e = - r**(-6) + GC6
             e = r**(-12) - GC12
          endif
    */
  } else if (vdw_model == NONE) {
    fij_vdw = 0.0f;
    if (calc_energy) {
      pot_vdw = 0.0f;
    }
  }

  return fij_vdw;
}

//static texture<float, 1, cudaReadModeElementType> ewald_force_texref;

//
// Returns simple linear interpolation
// NOTE: Could the interpolation be done implicitly using the texture unit?
//
__forceinline__ __device__ float lookup_force(const float r, const float hinv) {
  float r_hinv = r*hinv;
  int ind = (int)r_hinv;
  float f1 = r_hinv - (float)ind;
  float f2 = 1.0f - f1;
#if __CUDA_ARCH__ < 350
  return f1*d_setup.ewald_force[ind] + f2*d_setup.ewald_force[ind+1];
#else
  return f1*__ldg(&d_setup.ewald_force[ind]) + f2*__ldg(&d_setup.ewald_force[ind+1]);
#endif
  //return f1*tex1Dfetch(ewald_force_texref, ind) + f2*tex1Dfetch(ewald_force_texref, ind+1);
}

//
// Calculates electrostatic force & energy
//
template <int elec_model, bool calc_energy>
__forceinline__ __device__
float pair_elec_force(const float r2, const float r, const float rinv, 
		      const float qq, float &pot_elec) {

  float fij_elec;

  if (elec_model == EWALD_LOOKUP) {
    fij_elec = qq*lookup_force(r, d_setup.hinv);
  } else if (elec_model == EWALD) {
    float erfc_val = fasterfc(d_setup.kappa*r);
    float exp_val = expf(-d_setup.kappa2*r2);
    if (calc_energy) {
      pot_elec = qq*erfc_val*rinv;
    }
    const float two_sqrtpi = 1.12837916709551f;    // 2/sqrt(pi)
    fij_elec = qq*(two_sqrtpi*d_setup.kappa*exp_val + erfc_val*rinv);
  } else if (elec_model == GSHFT) {
    // GROMACS style shift 1/r^2 force
    // MGL special casing ctonnb=0 might speed this up
    // NOTE THAT THIS EXPLICITLY ASSUMES ctonnb = 0
    //ctofnb4 = ctofnb2*ctofnb2
    //ctofnb5 = ctofnb4*ctofnb
    fij_elec = qq*(rinv - (5.0f*d_setup.roffinv4*r - 4.0f*d_setup.roffinv5*r2)*r2 );
    //d = -qscale*(one/r2 - 5.0*r2/ctofnb4 +4*r2*r/ctofnb5)
    if (calc_energy) {
      pot_elec = qq*(rinv - d_setup.GAconst + (d_setup.GBcoef*r - d_setup.roffinv5*r2)*r2);
      //e = qscale*(one/r - GAconst + r*r2*GBcoef - r2*r2/ctofnb5)
    }
  } else if (elec_model == NONE) {
    fij_elec = 0.0f;
    if (calc_energy) {
      pot_elec = 0.0f;
    }
  }

  return fij_elec;
}

//
// Calculates electrostatic force & energy for 1-4 interactions and exclusions
//
template <int elec_model, bool calc_energy>
__forceinline__ __device__
float pair_elec_force_14(const float r2, const float r, const float rinv,
			 const float qq, const float e14fac, float &pot_elec) {

  float fij_elec;

  if (elec_model == EWALD) {
    float erfc_val = fasterfc(d_setup.kappa*r);
    float exp_val = expf(-d_setup.kappa2*r2);
    float qq_efac_rinv = qq*(erfc_val + e14fac - 1.0f)*rinv;
    if (calc_energy) {
      pot_elec = qq_efac_rinv;
    }
    const float two_sqrtpi = 1.12837916709551f;    // 2/sqrt(pi)
    fij_elec = -qq*two_sqrtpi*d_setup.kappa*exp_val - qq_efac_rinv;
  } else if (elec_model == NONE) {
    fij_elec = 0.0f;
    if (calc_energy) {
      pot_elec = 0.0f;
    }
  }

  return fij_elec;
}

//
// 1-4 exclusion force
//
template <typename AT, typename CT, int elec_model, bool calc_energy, bool calc_virial>
__device__ void calc_ex14_force_device(const int pos, const xx14list_t* ex14list,
				       const float4* xyzq, const int stride, AT *force,
				       double &elec_pot) {

  int i = ex14list[pos].i;
  int j = ex14list[pos].j;
  int ish = ex14list[pos].ishift;
  float3 sh_xyz = calc_box_shift(ish, d_setup.boxx, d_setup.boxy, d_setup.boxz);
  // Load atom coordinates
  float4 xyzqi = xyzq[i];
  float4 xyzqj = xyzq[j];
  // Calculate distance
  CT dx = xyzqi.x - xyzqj.x + sh_xyz.x;
  CT dy = xyzqi.y - xyzqj.y + sh_xyz.y;
  CT dz = xyzqi.z - xyzqj.z + sh_xyz.z;
  CT r2 = dx*dx + dy*dy + dz*dz;
  CT qq = ccelec*xyzqi.w*xyzqj.w;
  // Calculate the interaction
  CT r = sqrtf(r2);
  CT rinv = ((CT)1)/r;
  CT rinv2 = rinv*rinv;
  float dpot_elec;
  CT fij_elec = pair_elec_force_14<elec_model, calc_energy>(r2, r, rinv, qq,
							    0.0f, dpot_elec);
  if (calc_energy) elec_pot += (double)dpot_elec;
  CT fij = fij_elec*rinv2;
  // Calculate force components
  AT fxij, fyij, fzij;
  calc_component_force<AT, CT>(fij, dx, dy, dz, fxij, fyij, fzij);

  // Store forces
  write_force<AT>(fxij, fyij, fzij,    i, stride, force);
  write_force<AT>(-fxij, -fyij, -fzij, j, stride, force);
  // Store shifted forces
  if (calc_virial) {
    //sforce(is)   = sforce(is)   + fijx
    //sforce(is+1) = sforce(is+1) + fijy
    //sforce(is+2) = sforce(is+2) + fijz
  }

}

//
// 1-4 interaction force
//
template <typename AT, typename CT, int vdw_model, int elec_model, 
	  bool calc_energy, bool calc_virial, bool tex_vdwparam>
__device__ void calc_in14_force_device(
#ifdef USE_TEXTURE_OBJECTS
				       const cudaTextureObject_t tex,
#endif
				       const int pos, const xx14list_t* in14list,
				       const int* vdwtype, const float* vdwparam14,
				       const float4* xyzq, const int stride, AT *force,
				       double &vdw_pot, double &elec_pot) {

  int i = in14list[pos].i;
  int j = in14list[pos].j;
  int ish = in14list[pos].ishift;
  float3 sh_xyz = calc_box_shift(ish, d_setup.boxx, d_setup.boxy, d_setup.boxz);
  // Load atom coordinates
  float4 xyzqi = xyzq[i];
  float4 xyzqj = xyzq[j];
  // Calculate distance
  CT dx = xyzqi.x - xyzqj.x + sh_xyz.x;
  CT dy = xyzqi.y - xyzqj.y + sh_xyz.y;
  CT dz = xyzqi.z - xyzqj.z + sh_xyz.z;
  CT r2 = dx*dx + dy*dy + dz*dz;
  CT qq = ccelec*xyzqi.w*xyzqj.w;
  // Calculate the interaction
  CT r = sqrtf(r2);
  CT rinv = ((CT)1)/r;

  int ia = vdwtype[i];
  int ja = vdwtype[j];
  int aa = max(ja, ia);

  CT c6, c12;
  if (tex_vdwparam) {
    int ivdw = (aa*(aa-3) + 2*(ja + ia) - 2) >> 1;
    //c6 = __ldg(&vdwparam14[ivdw]);
    //c12 = __ldg(&vdwparam14[ivdw+1]);
#ifdef USE_TEXTURE_OBJECTS
    float2 c6c12 = tex1Dfetch<float2>(tex, ivdw);
#else
    float2 c6c12 = tex1Dfetch(vdwparam14_texref, ivdw);
#endif
    c6  = c6c12.x;
    c12 = c6c12.y;
  } else {
    int ivdw = (aa*(aa-3) + 2*(ja + ia) - 2);
    c6 = vdwparam14[ivdw];
    c12 = vdwparam14[ivdw+1];
  }

  CT rinv2 = rinv*rinv;

  float dpot_vdw;
  CT fij_vdw = pair_vdw_force<vdw_model, calc_energy>(r2, r, rinv, rinv2, c6, c12, dpot_vdw);
  if (calc_energy) vdw_pot += (double)dpot_vdw;

  float dpot_elec;
  CT fij_elec = pair_elec_force_14<elec_model, calc_energy>(r2, r, rinv, qq,
  							    d_setup.e14fac, dpot_elec);
  if (calc_energy) elec_pot += (double)dpot_elec;

  CT fij = (fij_vdw + fij_elec)*rinv2;

  // Calculate force components
  AT fxij, fyij, fzij;
  calc_component_force<AT, CT>(fij, dx, dy, dz, fxij, fyij, fzij);

  // Store forces
  write_force<AT>(fxij, fyij, fzij,    i, stride, force);
  write_force<AT>(-fxij, -fyij, -fzij, j, stride, force);
  
  // Store shifted forces
  if (calc_virial) {
    //sforce(is)   = sforce(is)   + fijx
    //sforce(is+1) = sforce(is+1) + fijy
    //sforce(is+2) = sforce(is+2) + fijz
  }

}

//
// 1-4 exclusion and interaction calculation kernel
//
template <typename AT, typename CT, int vdw_model, int elec_model, 
	  bool calc_energy, bool calc_virial, bool tex_vdwparam>
__global__ void calc_14_force_kernel(
#ifdef USE_TEXTURE_OBJECTS
				     const cudaTextureObject_t tex,
#endif
				     const int nin14list, const int nex14list,
				     const int nin14block,
				     const xx14list_t* in14list, const xx14list_t* ex14list,
				     const int* vdwtype, const float* vdwparam14,
				     const float4* xyzq, const int stride,
				     DirectEnergyVirial_t* __restrict__ energy_virial,
				     AT *force) {
  // Amount of shared memory required:
  // blockDim.x*sizeof(double2)
  extern __shared__ double2 shpot[];

  if (blockIdx.x < nin14block) {
    double vdw_pot, elec_pot;
    if (calc_energy) {
      vdw_pot = 0.0;
      elec_pot = 0.0;
    }

    int pos = threadIdx.x + blockIdx.x*blockDim.x;
    if (pos < nin14list) {
      calc_in14_force_device<AT, CT, vdw_model, elec_model, calc_energy, calc_virial, tex_vdwparam>
	(
#ifdef USE_TEXTURE_OBJECTS
	 tex,
#endif
	 pos, in14list, vdwtype, vdwparam14, xyzq, stride, force, vdw_pot, elec_pot);
    }

    if (calc_energy) {
      shpot[threadIdx.x].x = vdw_pot;
      shpot[threadIdx.x].y = elec_pot;
      __syncthreads();
      for (int i=1;i < blockDim.x;i *= 2) {
	int t = threadIdx.x + i;
	double val1 = (t < blockDim.x) ? shpot[t].x : 0.0;
	double val2 = (t < blockDim.x) ? shpot[t].y : 0.0;
	__syncthreads();
	shpot[threadIdx.x].x += val1;
	shpot[threadIdx.x].y += val2;
	__syncthreads();
      }
      if (threadIdx.x == 0) {
	atomicAdd(&energy_virial->energy_vdw,  shpot[0].x);
	atomicAdd(&energy_virial->energy_elec, shpot[0].y);
      }
    }

  } else {
    double excl_pot;
    if (calc_energy) excl_pot = 0.0;

    int pos = threadIdx.x + (blockIdx.x-nin14block)*blockDim.x;
    if (pos < nex14list) {
      calc_ex14_force_device<AT, CT, elec_model, calc_energy, calc_virial>
	(pos, ex14list, xyzq, stride, force, excl_pot);
    }

    if (calc_energy) {
      shpot[threadIdx.x].x = excl_pot;
      __syncthreads();
      for (int i=1;i < blockDim.x;i *= 2) {
	int t = threadIdx.x + i;
	double val = (t < blockDim.x) ? shpot[t].x : 0.0;
	__syncthreads();
	shpot[threadIdx.x].x += val;
	__syncthreads();
      }
      if (threadIdx.x == 0) {
	atomicAdd(&energy_virial->energy_excl,  shpot[0].x);
      }
    }

  }

}

#define CREATE_KERNEL(KERNEL_NAME, VDW_MODEL, ELEC_MODEL, CALC_ENERGY, CALC_VIRIAL, TEX_VDWPARAM, ...) \
  {									\
    KERNEL_NAME <AT, CT, tilesize, VDW_MODEL, ELEC_MODEL, CALC_ENERGY, CALC_VIRIAL, TEX_VDWPARAM> \
      <<< nblock, nthread, shmem_size, stream >>>			\
      (__VA_ARGS__);							\
  }

#define CREATE_KERNEL14(KERNEL_NAME, VDW_MODEL, ELEC_MODEL, CALC_ENERGY, CALC_VIRIAL, TEX_VDWPARAM, ...) \
  {									\
    KERNEL_NAME <AT, CT, VDW_MODEL, ELEC_MODEL, CALC_ENERGY, CALC_VIRIAL, TEX_VDWPARAM> \
      <<< nblock, nthread, shmem_size, stream >>>			\
      (__VA_ARGS__);							\
  }

#define EXPAND_ENERGY_VIRIAL(KERNEL_CREATOR, KERNEL_NAME, VDW_MODEL, ELEC_MODEL, ...) \
  {									\
    if (calc_energy) {							\
      if (calc_virial) {						\
	KERNEL_CREATOR(KERNEL_NAME, VDW_MODEL, ELEC_MODEL, true, true, USE_TEXTURES, __VA_ARGS__); \
      } else {								\
	KERNEL_CREATOR(KERNEL_NAME, VDW_MODEL, ELEC_MODEL, true, false, USE_TEXTURES, __VA_ARGS__); \
      }									\
    } else {								\
      if (calc_virial) {						\
	KERNEL_CREATOR(KERNEL_NAME, VDW_MODEL, ELEC_MODEL, false, true, USE_TEXTURES, __VA_ARGS__); \
      } else {								\
	KERNEL_CREATOR(KERNEL_NAME, VDW_MODEL, ELEC_MODEL, false, false, USE_TEXTURES, __VA_ARGS__); \
      }									\
    }									\
  }

#define EXPAND_ELEC(KERNEL_CREATOR, KERNEL_NAME, VDW_MODEL, ...)	\
  {									\
    if (elec_model == EWALD) {					\
      EXPAND_ENERGY_VIRIAL(KERNEL_CREATOR, KERNEL_NAME, VDW_MODEL, EWALD, __VA_ARGS__); \
    } else if (elec_model == EWALD_LOOKUP) {			\
      EXPAND_ENERGY_VIRIAL(KERNEL_CREATOR, KERNEL_NAME, VDW_MODEL, EWALD_LOOKUP, __VA_ARGS__); \
    } else if (elec_model == GSHFT) {				\
      EXPAND_ENERGY_VIRIAL(KERNEL_CREATOR, KERNEL_NAME, VDW_MODEL, GSHFT, __VA_ARGS__); \
    } else if (elec_model == NONE) {				\
      EXPAND_ENERGY_VIRIAL(KERNEL_CREATOR, KERNEL_NAME, VDW_MODEL, NONE, __VA_ARGS__); \
    } else {								\
      std::cout<<__func__<<" Invalid EWALD model "<<elec_model<<std::endl; \
      exit(1);								\
    }									\
  }

#define CREATE_KERNELS(KERNEL_CREATOR, KERNEL_NAME, ...)		\
  {									\
    if (vdw_model == VDW_VSH) {					\
      EXPAND_ELEC(KERNEL_CREATOR, KERNEL_NAME, VDW_VSH, __VA_ARGS__);	\
    } else if (vdw_model == VDW_VSW) {				\
      EXPAND_ELEC(KERNEL_CREATOR, KERNEL_NAME, VDW_VSW, __VA_ARGS__);	\
    } else if (vdw_model == VDW_VFSW) {				\
      EXPAND_ELEC(KERNEL_CREATOR, KERNEL_NAME, VDW_VFSW, __VA_ARGS__);	\
    } else if (vdw_model == VDW_CUT) {				\
      EXPAND_ELEC(KERNEL_CREATOR, KERNEL_NAME, VDW_CUT, __VA_ARGS__);	\
    } else if (vdw_model == VDW_VGSH) {				\
      EXPAND_ELEC(KERNEL_CREATOR, KERNEL_NAME, VDW_VGSH, __VA_ARGS__);	\
    } else {								\
      std::cout<<__func__<<" Invalid VDW model "<<vdw_model<<std::endl; \
      exit(1);								\
    }									\
  }

//--------------------------------------------------------------
//-------------------- Regular version -------------------------
//--------------------------------------------------------------

#define CUDA_KERNEL_NAME calcForceKernel
#include "CudaDirectForce_util.h"
#undef CUDA_KERNEL_NAME

//------------------------------------------------------------
//-------------------- Block version -------------------------
//------------------------------------------------------------

#undef NUMBLOCK_LARGE

#define USE_BLOCK
#define CUDA_KERNEL_NAME calcForceBlockKernel
#include "CudaDirectForce_util.h"
#undef USE_BLOCK
#undef CUDA_KERNEL_NAME

//------------------------------------------------------------
//------------------------------------------------------------
//------------------------------------------------------------

template <typename AT, typename CT>
void calcForceKernelChoice(const int nblock_tot_in, const int nthread, const int shmem_size, cudaStream_t stream,
			   const int vdw_model, const int elec_model, const bool calc_energy, const bool calc_virial,
			   const CudaNeighborListBuild<32>& nlist,
			   const int stride, const float* vdwparam, const int nvdwparam, const float4* xyzq,
			   const int* vdwtype, DirectEnergyVirial_t* d_energy_virial, AT* force,
			   CudaBlock* cudaBlock, AT* biflam, AT* biflam2) {

  int nblock_tot = nblock_tot_in;
  int3 max_nblock3 = get_max_nblock();
  unsigned int max_nblock = max_nblock3.x;
  unsigned int base = 0;

  while (nblock_tot != 0) {

    int nblock = (nblock_tot > max_nblock) ? max_nblock : nblock_tot;
    nblock_tot -= nblock;

    if (cudaBlock == NULL) {
      /*
      fprintf(stderr,"shmem_size = %d\n",shmem_size);
      calcForceKernel<AT, CT, tilesize, VDW_VSH, EWALD, false, false, true>
	<<< nblock, nthread, shmem_size, stream >>>
	(base, nlist.get_n_ientry(), nlist.get_ientry(), nlist.get_tile_indj(),
	 nlist.get_tile_excl(), stride, vdwparam, nvdwparam, xyzq, vdwtype,
	 d_energy_virial, force);
      */
#ifdef USE_TEXTURE_OBJECTS
      CREATE_KERNELS(CREATE_KERNEL, calcForceKernel, vdwparam_tex,
		     base, nlist.get_n_ientry(), nlist.get_ientry(), nlist.get_tile_indj(),
		     nlist.get_tile_excl(), stride, vdwparam, nvdwparam, xyzq, vdwtype,
		     d_energy_virial, force);
#else
      CREATE_KERNELS(CREATE_KERNEL, calcForceKernel,
		     base, nlist.get_n_ientry(), nlist.get_ientry(), nlist.get_tile_indj(),
		     nlist.get_tile_excl(), stride, vdwparam, nvdwparam, xyzq, vdwtype,
		     d_energy_virial, force);
#endif
    } else {
#ifdef USE_TEXTURE_OBJECTS
      CREATE_KERNELS(CREATE_KERNEL, calcForceBlockKernel, vdwparam_tex,
		     base, nlist.get_n_ientry(), nlist.get_ientry(), nlist.get_tile_indj(),
		     nlist.get_tile_excl(), stride, vdwparam, nvdwparam, xyzq, vdwtype,
		     cudaBlock->getNumBlock(), cudaBlock->getBixlam(), cudaBlock->getBlockType(),
		     biflam, biflam2, cudaBlock->getBlockParamTexObj(), d_energy_virial, force);
#else
      CREATE_KERNELS(CREATE_KERNEL, calcForceBlockKernel,
		     base, nlist.get_n_ientry(), nlist.get_ientry(), nlist.get_tile_indj(),
		     nlist.get_tile_excl(), stride, vdwparam, nvdwparam, xyzq, vdwtype,
		     cudaBlock->getNumBlock(), cudaBlock->getBixlam(), cudaBlock->getBlockType(),
		     biflam, biflam2, d_energy_virial, force);
#endif
    }
    
    base += (nthread/warpsize)*nblock;

    cudaCheck(cudaGetLastError());
  }
}

template <typename AT, typename CT>
void calcForce14KernelChoice(const int nblock, const int nthread, const int shmem_size, cudaStream_t stream,
			     const int vdw_model, const int elec_model, const bool calc_energy, const bool calc_virial,
			     const int nin14list, const xx14list_t* in14list, const int nex14list, const xx14list_t* ex14list,
			     const int nin14block, const int* vdwtype, const float* vdwparam14, const float4* xyzq,
			     const int stride, DirectEnergyVirial_t* d_energy_virial, AT* force) {
  
#ifdef USE_TEXTURE_OBJECTS
  CREATE_KERNELS(CREATE_KERNEL14, calc_14_force_kernel, vdwparam14_tex,
		 nin14list, nex14list, nin14block, in14list, ex14list,
		 vdwtype, vdwparam14, xyzq, stride, d_energy_virial, force);
#else
  CREATE_KERNELS(CREATE_KERNEL14, calc_14_force_kernel,
		 nin14list, nex14list, nin14block, in14list, ex14list,
		 vdwtype, vdwparam14, xyzq, stride, d_energy_virial, force);
#endif

  cudaCheck(cudaGetLastError());
}

template <typename AT, typename CT>
void calcVirial(const int ncoord, const float4 *xyzq,
		DirectEnergyVirial_t* d_energy_virial,
		const int stride, AT *force,
		cudaStream_t stream) {

  int nthread, nblock, shmem_size;
  nthread = 256;
  nblock = (ncoord+27-1)/nthread + 1;
  shmem_size = nthread*3*sizeof(double);

  calc_virial_kernel <AT, CT>
    <<< nblock, nthread, shmem_size, stream>>>
    (ncoord, xyzq, stride, d_energy_virial, force);

  cudaCheck(cudaGetLastError());
}

void updateDirectForceSetup(const DirectSettings_t* h_setup) {
 cudaCheck(cudaMemcpyToSymbol(d_setup, h_setup, sizeof(DirectSettings_t)));
}
 
template void calcForceKernelChoice<long long int, float>
(const int nblock_tot_in, const int nthread, const int shmem_size, cudaStream_t stream,
 const int vdw_model, const int elec_model, const bool calc_energy, const bool calc_virial,
 const CudaNeighborListBuild<32>& nlist,
 const int stride, const float* vdwparam, const int nvdwparam, const float4* xyzq,
 const int* vdwtype, DirectEnergyVirial_t* d_energy_virial, long long int* force,
 CudaBlock* cudaBlock, long long int* biflam, long long int* biflam2);

template void calcForce14KernelChoice<long long int, float>
(const int nblock, const int nthread, const int shmem_size, cudaStream_t stream,
 const int vdw_model, const int elec_model, const bool calc_energy, const bool calc_virial,
 const int nin14list, const xx14list_t* in14list, const int nex14list, const xx14list_t* ex14list,
 const int nin14block, const int* vdwtype, const float* vdwparam14, const float4* xyzq,
 const int stride, DirectEnergyVirial_t* d_energy_virial, long long int* force);

template void calcVirial<long long int, float>
(const int ncoord, const float4 *xyzq,
 DirectEnergyVirial_t* d_energy_virial,
 const int stride, long long int* force,
 cudaStream_t stream);
