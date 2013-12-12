#ifndef BSPLINE_H
#define BSPLINE_H

template <typename T> class Bspline {

private:

  // Length of the B-spline data arrays
  int thetax_len;
  int thetay_len;
  int thetaz_len;
  int dthetax_len;
  int dthetay_len;
  int dthetaz_len;

  // Size of the FFT
  int nfftx;
  int nffty;
  int nfftz;

  // B-spline order
  int order;

  // Length of the data arrays
  int gix_len;
  int giy_len;
  int giz_len;
  int charge_len;

  // Reciprocal vectors
  T* recip;

public:

  // B-spline data
  T *thetax;
  T *thetay;
  T *thetaz;
  T *dthetax;
  T *dthetay;
  T *dthetaz;

  // prefac arrays
  T* prefac_x;
  T* prefac_y;
  T* prefac_z;

  // Grid positions and charge of the atoms
  int *gix;
  int *giy;
  int *giz;
  T *charge;

private:

  void set_ncoord(const int ncoord);
  void dftmod(double *bsp_mod, const double *bsp_arr, const int nfft);
  void fill_bspline_host(const double w, double *array, double *darray);

public:

  Bspline(const int ncoord, const int order, const int nfftx, const int nffty, const int nfftz);
  ~Bspline();

  template <typename B>
  void set_recip(const B *recip);

  void fill_bspline(const float4 *xyzq, const int ncoord);
  void calc_prefac();
};

#endif // BSPLINE_H