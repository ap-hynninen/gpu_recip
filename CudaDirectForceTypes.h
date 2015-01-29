#ifndef CUDADIRECTFORCETYPES_H
#define CUDADIRECTFORCETYPES_H

struct DirectEnergyVirial_t {
  // Energies
  double energy_vdw;
  double energy_elec;
  double energy_excl;

  // Finished virial
  double vir[9];

  // Shift forces for virial calculation
  double sforcex[27];
  double sforcey[27];
  double sforcez[27];

};

struct DirectSettings_t {
  float kappa;
  float kappa2;

  float boxx;
  float boxy;
  float boxz;

  float roff2;
  float ron2;
  float ron;

  float roffinv3;
  float roffinv4;
  float roffinv5;
  float roffinv6;
  float roffinv12;
  float roffinv18;

  float inv_roff2_ron2;

  float k6, k12, dv6, dv12;

  float ga6, gb6, gc6;
  float ga12, gb12, gc12;
  float GAconst, GBcoef;

  float e14fac;

  float hinv;
  float *ewald_force;

};

// Enum for VdW and electrostatic models
enum {NONE=0, 
      VDW_VSH=1, VDW_VSW=2, VDW_VFSW=3, VDW_VGSH=4, VDW_CUT=5,
      EWALD=101, CSHIFT=102, CFSWIT=103, CSHFT=104, CSWIT=105, RSWIT=106,
      RSHFT=107, RSHIFT=108, RFSWIT=109, GSHFT=110, EWALD_LOOKUP=111};

// Enum for vdwparam
enum {VDW_MAIN, VDW_IN14};

#endif // CUDADIRECTFORCETYPES_H
