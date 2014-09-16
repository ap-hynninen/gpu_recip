#ifndef CUDAMPI_H
#define CUDAMPI_H

#ifdef USE_MPI
#include <mpi.h>
#endif

class CudaMPI {

 private:
  bool CudaAware;
  MPI_Comm comm;

 public:

 CudaMPI(bool CudaAware, MPI_Comm comm) : CudaAware(CudaAware), comm(comm) {};
  ~CudaMPI() {};

#ifdef USE_MPI
  int Isend(void *buf, int count, int dest, int tag, MPI_Request *request, void *h_buf);
  int Recv(void *buf, int count, int source, int tag, MPI_Status *status, void *h_buf);
#endif

  bool isCudaAware() {return CudaAware;}
  MPI_Comm get_comm() {return comm;}

};

#endif // CUDAMPI_H
