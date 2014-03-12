#ifndef NEIGHBORLIST_H
#define NEIGHBORLIST_H

#include <cuda.h>

template <int tilesize>
struct num_excl {
  static const int val = ((tilesize*tilesize-1)/32 + 1);
};

template <int tilesize>
struct tile_excl_t {
  unsigned int excl[num_excl<tilesize>::val]; // Exclusion mask
};

struct ientry_t {
  int indi;
  int ish;
  int startj;
  int endj;
};

template <int tilesize>
struct pairs_t {
  int i[tilesize];
};

//
// Bounding box structure
//
struct bb_t {
  float x, y, z;      // Center
  float wx, wy, wz;   // Half-width
};

template<typename AT, typename CT> class DirectForce;

template <int tilesize>
class NeighborList {
  friend class DirectForce<long long int, float>;
private:

  // Number of i tiles
  int ni;

  // Total number of tiles
  int ntot;

  int tile_excl_len;
  tile_excl_t<tilesize> *tile_excl;

  int ientry_len;
  ientry_t *ientry;

  int tile_indj_len;
  int *tile_indj;

  // Sparse:
  int ni_sparse;

  int ntot_sparse;

  int pairs_len;
  pairs_t<tilesize> *pairs;
  
  int ientry_sparse_len;
  ientry_t *ientry_sparse;

  int tile_indj_sparse_len;
  int *tile_indj_sparse;

  // For building neighbor list on GPU
  int ncellx, ncelly, ncellz;
  
  int tilex_key_len;
  int *tilex_key;

  int tilex_val_len;
  int *tilex_val;

  int bb_len;
  bb_t *bb;

public:
  NeighborList();
  ~NeighborList();

  void sort_tilex(const int ncoord,
		  const float x0, const float y0, const float z0,
		  const float inv_dx, const float inv_dy, const float inv_dz,
		  const float4 *xyzq,
		  float4 *xyzq_sorted,
		  cudaStream_t stream);

  void calc_bounding_box(const int ncell,
			 const int *cell_start,
			 const float4 *xyzq,
			 cudaStream_t stream);

  void build_excl(const float boxx, const float boxy, const float boxz,
		  const float roff,
		  const int n_ijlist, const int3 *ijlist,
		  const int *cell_start,
		  const float4 *xyzq,
		  cudaStream_t stream=0);
  
  void add_tile_top(const int ntile_top, const int *tile_ind_top,
		    const tile_excl_t<tilesize> *tile_excl_top,
		    cudaStream_t stream=0);

  void set_ientry(int ni, ientry_t *h_ientry, cudaStream_t stream=0);

  void split_dense_sparse(int npair_cutoff);
  void remove_empty_tiles();
  void analyze();
  void load(const char *filename);
};

#endif // NEIGHBORLIST_H
