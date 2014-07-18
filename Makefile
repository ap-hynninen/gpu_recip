
# Detect OS
OS := $(shell uname -s)

# Detect Intel compiler
INTEL_COMPILER := $(shell which icc | wc -l)

MPI_FOUND := $(shell which mpicc | wc -l )

DEFS := DONT_USE_MPI
ifeq ($(MPI_FOUND),1)
DEFS := USE_MPI
endif

CCMPI = mpicc
CLMPI = mpicc

ifeq ($(INTEL_COMPILER),1)
CC = icc
CL = icc
else
CC = g++
CL = g++
endif

ifeq ($(INTEL_COMPILER),1)
OPENMP_OPT = -openmp
else
OPENMP_OPT = -fopenmp
endif

SRC = BondedForce.cu NeighborList.cu Bspline.cu VirialPressure.cu CudaDomdec.cu	XYZQ.cu CudaLeapfrogIntegrator.cu cuda_utils.cu CudaPMEForcefield.cu CudaPMEDirectForce.cu CudaPMEDirectForceBlock.cu gpu_bonded.cu gpu_const.cu Force.cu reduce.cu gpu_direct.cu Grid.cu gpu_dyna.cu HoloConst.cu gpu_recip.cu Matrix3d.cu MultiNodeMatrix3d.cpp mpi_utils.cpp CudaDomdecBonded.cu cpu_transpose.cpp CpuMultiNodeMatrix3d.cpp CpuMatrix3d.cpp

OBJS_RECIP = Grid.o Bspline.o XYZQ.o Matrix3d.o Force.o reduce.o cuda_utils.o gpu_recip.o

OBJS_DIRECT = XYZQ.o Force.o reduce.o cuda_utils.o CudaPMEDirectForce.o CudaPMEDirectForceBlock.o NeighborList.o VirialPressure.o BondedForce.o gpu_direct.o

OBJS_BONDED = XYZQ.o Force.o reduce.o cuda_utils.o VirialPressure.o BondedForce.o gpu_bonded.o

OBJS_CONST = cuda_utils.o gpu_const.o HoloConst.o

OBJS_DYNA = cuda_utils.o gpu_dyna.o Force.o reduce.o CudaLeapfrogIntegrator.o CudaPMEForcefield.o NeighborList.o CudaPMEDirectForce.o BondedForce.o Grid.o Matrix3d.o XYZQ.o CudaDomdec.o CudaDomdecBonded.o HoloConst.o

OBJS_TRANSPOSE = cpu_transpose.o mpi_utils.o CpuMultiNodeMatrix3d.o CpuMatrix3d.o

CUDAROOT := $(subst /bin/,,$(dir $(shell which nvcc)))

ifeq ($(OS),Linux)
LFLAGS = -std=c++0x -L $(CUDAROOT)/lib64 -lcudart -lnvToolsExt -lcufft
else
LFLAGS = -L /usr/local/cuda/lib -I /usr/local/cuda/include -lcudart -lcufft -lcuda -lstdc++.6 -lnvToolsExt
endif

ifeq ($(INTEL_COMPILER),1)
CFLAGS = -O3 -std=c++0x
else
CFLAGS = -O3 -std=c++0x #-std=c++11
endif

GENCODE_SM20  := -gencode arch=compute_20,code=sm_20
GENCODE_SM30  := -gencode arch=compute_30,code=sm_30
GENCODE_SM35  := -gencode arch=compute_35,code=sm_35
GENCODE_FLAGS := $(GENCODE_SM20) $(GENCODE_SM30) $(GENCODE_SM35)

exec_targets := gpu_direct gpu_bonded gpu_recip gpu_const gpu_dyna
ifeq ($(MPI_FOUND),1)
exec_targets += cpu_transpose
endif

all: $(exec_targets)

gpu_recip : $(OBJS_RECIP)
	$(CL) $(LFLAGS) -o gpu_recip $(OBJS_RECIP)

gpu_direct : $(OBJS_DIRECT)
	$(CL) $(LFLAGS) -o gpu_direct $(OBJS_DIRECT)

gpu_bonded : $(OBJS_BONDED)
	$(CL) $(LFLAGS) -o gpu_bonded $(OBJS_BONDED)

gpu_const : $(OBJS_CONST)
	$(CL) $(LFLAGS) -o gpu_const $(OBJS_CONST)

gpu_dyna : $(OBJS_DYNA)
	$(CL) $(LFLAGS) -o gpu_dyna $(OBJS_DYNA)

cpu_transpose : $(OBJS_TRANSPOSE)
	$(CCMPI) $(LFLAGS) $(OPENMP_OPT) -o cpu_transpose $(OBJS_TRANSPOSE)

clean: 
	rm -f *.o
	rm -f *~
	rm -f gpu_recip
	rm -f gpu_direct
	rm -f gpu_bonded
	rm -f gpu_const
	rm -f gpu_dyna
	rm -f cpu_transpose

depend:
	makedepend $(SRC)

%.o : %.cu
	nvcc -c -O3 $(GENCODE_FLAGS) -lineinfo -fmad=true -use_fast_math -D$(DEFS) $<

CpuMultiNodeMatrix3d.o : CpuMultiNodeMatrix3d.cpp
	$(CCMPI) -c $(CFLAGS) $(OPENMP_OPT) -D$(DEFS) $<

MultiNodeMatrix3d.o : MultiNodeMatrix3d.cpp
	$(CCMPI) -c $(CFLAGS) $(OPENMP_OPT) -D$(DEFS) $<

cpu_transpose.o : cpu_transpose.cpp
	$(CCMPI) -c $(CFLAGS) $(OPENMP_OPT) -D$(DEFS) $<

mpi_utils.o : mpi_utils.cpp
	$(CCMPI) -c $(CFLAGS) -D$(DEFS) $<

%.o : %.cpp
	$(CC) -c $(CFLAGS) $(OPENMP_OPT) -D$(DEFS) $<

# DO NOT DELETE

BondedForce.o: cuda_utils.h gpu_utils.h
BondedForce.o: BondedForce.h Bonded_struct.h
NeighborList.o: gpu_utils.h cuda_utils.h NeighborList.h
Bspline.o: cuda_utils.h Bspline.h
VirialPressure.o: gpu_utils.h
VirialPressure.o: cuda_utils.h VirialPressure.h cudaXYZ.h XYZ.h Force.h
VirialPressure.o: hostXYZ.h
CudaDomdec.o: gpu_utils.h
CudaDomdec.o: CudaDomdec.h Decomp.h cudaXYZ.h
CudaDomdec.o: cuda_utils.h XYZ.h Force.h hostXYZ.h
XYZQ.o: cuda_utils.h gpu_utils.h XYZQ.h
XYZQ.o: cudaXYZ.h XYZ.h
CudaLeapfrogIntegrator.o: CudaLeapfrogIntegrator.h LeapfrogIntegrator.h
CudaLeapfrogIntegrator.o: Forcefield.h
CudaLeapfrogIntegrator.o: cudaXYZ.h cuda_utils.h XYZ.h Force.h hostXYZ.h
CudaLeapfrogIntegrator.o: CudaPMEForcefield.h CudaForcefield.h XYZQ.h
CudaLeapfrogIntegrator.o: NeighborList.h CudaPMEDirectForce.h Bonded_struct.h
CudaLeapfrogIntegrator.o: BondedForce.h Grid.h Bspline.h Matrix3d.h
CudaLeapfrogIntegrator.o: CudaDomdec.h Decomp.h CudaDomdecBonded.h
CudaLeapfrogIntegrator.o: HoloConst.h gpu_utils.h
cuda_utils.o: gpu_utils.h cuda_utils.h CudaPMEForcefield.h
CudaPMEForcefield.o: CudaForcefield.h Forcefield.h cudaXYZ.h cuda_utils.h
CudaPMEForcefield.o: XYZ.h Force.h hostXYZ.h XYZQ.h NeighborList.h
CudaPMEForcefield.o: CudaPMEDirectForce.h Bonded_struct.h BondedForce.h
CudaPMEForcefield.o: Grid.h Bspline.h Matrix3d.h CudaDomdec.h Decomp.h
CudaPMEForcefield.o: CudaDomdecBonded.h gpu_utils.h
CudaPMEDirectForce.o: gpu_utils.h cuda_utils.h
CudaPMEDirectForce.o: NeighborList.h CudaPMEDirectForce.h Bonded_struct.h
CudaPMEDirectForceBlock.o: cuda_utils.h
CudaPMEDirectForceBlock.o: NeighborList.h CudaPMEDirectForceBlock.h
CudaPMEDirectForceBlock.o: CudaPMEDirectForce.h Bonded_struct.h
gpu_bonded.o: cuda_utils.h gpu_utils.h XYZQ.h cudaXYZ.h XYZ.h Force.h
gpu_bonded.o: hostXYZ.h BondedForce.h Bonded_struct.h VirialPressure.h
gpu_const.o: cuda_utils.h gpu_utils.h HoloConst.h cudaXYZ.h XYZ.h
gpu_const.o: hostXYZ.h
Force.o: gpu_utils.h reduce.h
Force.o: cuda_utils.h Force.h cudaXYZ.h XYZ.h hostXYZ.h
reduce.o: gpu_utils.h
gpu_direct.o: cuda_utils.h XYZQ.h cudaXYZ.h XYZ.h Force.h hostXYZ.h
gpu_direct.o: NeighborList.h CudaPMEDirectForce.h Bonded_struct.h
gpu_direct.o: CudaPMEDirectForceBlock.h VirialPressure.h
Grid.o: cuda_utils.h reduce.h Matrix3d.h
Grid.o: MultiNodeMatrix3d.h Grid.h Bspline.h
gpu_dyna.o: cuda_utils.h gpu_utils.h CudaLeapfrogIntegrator.h
gpu_dyna.o: LeapfrogIntegrator.h Forcefield.h cudaXYZ.h XYZ.h Force.h
gpu_dyna.o: hostXYZ.h CudaPMEForcefield.h CudaForcefield.h XYZQ.h
gpu_dyna.o: NeighborList.h CudaPMEDirectForce.h Bonded_struct.h BondedForce.h
gpu_dyna.o: Grid.h Bspline.h Matrix3d.h CudaDomdec.h Decomp.h
gpu_dyna.o: CudaDomdecBonded.h HoloConst.h
HoloConst.o: gpu_utils.h cuda_utils.h HoloConst.h cudaXYZ.h
HoloConst.o: XYZ.h
gpu_recip.o: cuda_utils.h XYZQ.h cudaXYZ.h XYZ.h Bspline.h Grid.h Matrix3d.h
gpu_recip.o: Force.h hostXYZ.h
Matrix3d.o: gpu_utils.h cuda_utils.h Matrix3d.h
MultiNodeMatrix3d.o: cuda_utils.h MultiNodeMatrix3d.h Matrix3d.h
mpi_utils.o: mpi_utils.h CudaDomdecBonded.o: cuda_utils.h gpu_utils.h
CudaDomdecBonded.o: CudaDomdecBonded.h
CudaDomdecBonded.o: Bonded_struct.h CudaDomdec.h Decomp.h cudaXYZ.h XYZ.h
CudaDomdecBonded.o: Force.h hostXYZ.h
cpu_transpose.o: CpuMatrix3d.h mpi_utils.h CpuMultiNodeMatrix3d.h
CpuMultiNodeMatrix3d.o: mpi_utils.h
CpuMultiNodeMatrix3d.o: cpu_utils.h CpuMultiNodeMatrix3d.h CpuMatrix3d.h
CpuMatrix3d.o: cpu_utils.h CpuMatrix3d.h
