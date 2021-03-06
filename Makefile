
# Detect OS
ifeq ($(shell uname -a|grep Linux|wc -l), 1)
OS = linux
endif

ifeq ($(shell uname -a|grep titan|wc -l), 1)
OS = titan
endif

ifeq ($(shell uname -a|grep Darwin|wc -l), 1)
OS = osx
endif

YES := $(shell which make | wc -l 2> /dev/null)
NO := $(shell which pikaboo | wc -l 2> /dev/null)

# Set optimization level
#OPTLEV = -g
OPTLEV = -O3

# Detect CUDA, Intel compiler, and MPI
ifeq ($(OS),titan)
MPI_FOUND := $(YES)
else
MPI_FOUND := $(shell which mpicc | wc -l 2> /dev/null)
endif

CUDA_COMPILER := $(shell which nvcc | wc -l 2> /dev/null)
INTEL_COMPILER := $(shell which icc | wc -l 2> /dev/null)
XLC_COMPILER := $(shell which xlc++ | wc -l 2> /dev/null)

ifeq ($(XLC_COMPILER), $(YES))
MPI_FOUND := $(shell which mpcc | wc -l 2> /dev/null)
endif

ifeq ($(MPI_FOUND), $(YES))

DEFS = -D USE_MPI
#-D USE_FBFFT

ifeq ($(OS),titan)
CC = CC
CL = CC
else  # ifeq ($(OS),titan)

ifeq ($(INTEL_COMPILER), $(YES))
CC = mpicc
CL = mpicc
DEFS += -D MPICH_IGNORE_CXX_SEEK
else
ifeq ($(XLC_COMPILER), $(YES))
CC = mpCC -compiler xlc++
CL = mpCC -compiler xlc++
else
CC = mpic++
CL = mpic++
endif
endif

endif  # ifeq ($(OS),titan)

else   # MPI_FOUND

DEFS = -D DONT_USE_MPI

ifeq ($(INTEL_COMPILER), $(YES))
CC = icc
CL = icc
DEFS += -D MPICH_IGNORE_CXX_SEEK
else
ifeq ($(XLC_COMPILER), $(YES))
CC = xlc++
CL = xlc++
else
CC = g++
CL = g++
endif
endif

endif  # MPI_FOUND

# NOTE: CUDA texture objects require Kepler GPU + CUDA 5.0
DEFS += -D USE_TEXTURE_OBJECTS

OBJS_RECIP = CudaPMERecip.o Bspline.o XYZQ.o Matrix3d.o Force.o reduce.o cuda_utils.o gpu_recip.o \
	EnergyVirial.o CudaEnergyVirial.o

OBJS_DIRECT = XYZQ.o Force.o reduce.o cuda_utils.o CudaPMEDirectForce.o \
	CudaNeighborList.o CudaNeighborListSort.o CudaNeighborListBuild.o \
	CudaTopExcl.o gpu_direct.o CudaPMEDirectForceBlock.o CudaBlock.o \
	CudaDirectForceKernels.o EnergyVirial.o CudaEnergyVirial.o

OBJS_BONDED = XYZQ.o Force.o reduce.o cuda_utils.o CudaBondedForce.o gpu_bonded.o EnergyVirial.o CudaEnergyVirial.o

OBJS_CONST = cuda_utils.o gpu_const.o HoloConst.o

OBJS_DYNA = cuda_utils.o gpu_dyna.o Force.o reduce.o CudaLeapfrogIntegrator.o CudaPMEForcefield.o \
	CudaNeighborList.o CudaNeighborListSort.o CudaNeighborListBuild.o CudaTopExcl.o \
	CudaPMEDirectForce.o CudaBondedForce.o CudaPMERecip.o Matrix3d.o XYZQ.o CudaDomdec.o \
	CudaDomdecGroups.o HoloConst.o CudaDomdecHomezone.o CudaMPI.o mpi_utils.o CudaDomdecD2DComm.o \
	DomdecD2DComm.o DomdecRecipComm.o CudaDomdecRecipComm.o CudaDomdecRecipLooper.o Domdec.o \
	CudaDomdecConstComm.o CudaDirectForceKernels.o EnergyVirial.o CudaEnergyVirial.o

OBJS_PAIR = gpu_pair.o CudaPMERecip.o Force.o XYZQ.o cuda_utils.o reduce.o Matrix3d.o EnergyVirial.o CudaEnergyVirial.o

OBJS_FBFFT = test_fbfft.o cuda_utils.o

OBJS_TRANSPOSE = cpu_transpose.o mpi_utils.o CpuMultiNodeMatrix3d.o CpuMatrix3d.o

ifeq ($(CUDA_COMPILER), $(YES))
OBJS = $(OBJS_RECIP)
OBJS += $(OBJS_DIRECT)
OBJS += $(OBJS_BONDED)
OBJS += $(OBJS_CONST)
OBJS += $(OBJS_DYNA)
OBJS += $(OBJS_PAIR)
OBJS += $(OBJS_FBFFT)
endif
ifeq ($(MPI_FOUND), $(YES))
OBJS += $(OBJS_TRANSPOSE)
endif

ifeq ($(CUDA_COMPILER), $(YES))
CUDAROOT = $(subst /bin/,,$(dir $(shell which nvcc)))
endif

ifeq ($(MPI_FOUND), $(YES))
ifeq ($(OS),titan)
# NOTE: Assumes we're using Intel compiler
#MPIROOT = $(subst /bin/,,$(dir $(shell which icc)))
MPIROOT = /opt/cray/mpt/6.3.0/gni/mpich2-intel/130
else
MPIROOT = $(subst /bin/,,$(dir $(shell which mpicc)))
endif
endif

ifeq ($(INTEL_COMPILER), $(YES))
OPENMP_OPT = -openmp
else
ifeq ($(XLC_COMPILER), $(YES))
OPENMP_OPT = -qsmp=omp
else
OPENMP_OPT = -fopenmp
endif
endif

ifeq ($(CUDA_COMPILER), $(YES))
GENCODE_SM20  := -gencode arch=compute_20,code=sm_20
GENCODE_SM30  := -gencode arch=compute_30,code=sm_30
GENCODE_SM35  := -gencode arch=compute_35,code=sm_35
GENCODE_SM50  := -gencode arch=compute_50,code=sm_50
# See if CUDA compiler supports compute 5.0, also disable 5.0 for Titan
ifeq ($(OS),titan)
# Titan, K20x GPUs
GENCODE_FLAGS := $(GENCODE_SM35)
else
# Some other system
GENCODE_FLAGS := $(GENCODE_SM30) $(GENCODE_SM35)
ifneq ($(shell nvcc --help|grep compute_50|wc -l), 0)
GENCODE_FLAGS += $(GENCODE_SM50)
endif
endif
endif

# CUDA_CFLAGS = flags for compiling CUDA API calls using c compiler
# NVCC_CFLAGS = flags for nvcc compiler
# CUDA_LFLAGS = flags for linking with CUDA

CUDA_CFLAGS = -I${CUDAROOT}/include $(OPTLEV) $(OPENMP_OPT)
ifeq ($(XLC_COMPILER), $(NO))
CUDA_FLAGS += -std=c++0x
endif
NVCC_CFLAGS = $(OPTLEV) -lineinfo -fmad=true -use_fast_math $(GENCODE_FLAGS) --disable-warnings
ifeq ($(XLC_COMPILER), $(YES))
MPI_CFLAGS = -I/opt/ibmhpc/pecurrent/mpich/gnu/include64
else
MPI_CFLAGS = -I${MPIROOT}/include
endif

ifeq ($(OS),linux)
CUDA_LFLAGS = -L$(CUDAROOT)/lib64
else
ifeq ($(OS),titan)
CUDA_LFLAGS = -L$(CUDAROOT)/lib64
else
CUDA_LFLAGS = -L$(CUDAROOT)/lib
endif
endif
CUDA_LFLAGS += -lcudart -lcufft -lnvToolsExt

ifeq ($(CUDA_COMPILER), $(YES))
BINARIES = gpu_bonded gpu_recip gpu_const gpu_dyna gpu_direct gpu_pair test_fbfft
endif
ifeq ($(MPI_FOUND), $(YES))
BINARIES += cpu_transpose
endif

all: $(BINARIES)

gpu_recip : $(OBJS_RECIP)
	$(CL) $(CUDA_LFLAGS) -o gpu_recip $(OBJS_RECIP)

gpu_direct : $(OBJS_DIRECT)
	$(CL) $(CUDA_LFLAGS) -o gpu_direct $(OBJS_DIRECT)

gpu_bonded : $(OBJS_BONDED)
	$(CL) $(CUDA_LFLAGS) -o gpu_bonded $(OBJS_BONDED)

gpu_const : $(OBJS_CONST)
	$(CL) $(CUDA_LFLAGS) -o gpu_const $(OBJS_CONST)

gpu_dyna : $(OBJS_DYNA)
	$(CL) $(OPTLEV) $(CUDA_LFLAGS) -o gpu_dyna $(OBJS_DYNA)

gpu_pair : $(OBJS_PAIR)
	$(CL) $(OPTLEV) $(CUDA_LFLAGS) -o gpu_pair $(OBJS_PAIR)

test_fbfft : $(OBJS_FBFFT)
	$(CL) $(OPTLEV) $(CUDA_LFLAGS) -o test_fbfft $(OBJS_FBFFT)

cpu_transpose : $(OBJS_TRANSPOSE)
	$(CL) $(CUDA_LFLAGS) $(OPENMP_OPT) -o cpu_transpose $(OBJS_TRANSPOSE)

clean: 
	rm -f *.o
	rm -f *.d
	rm -f *~
	rm -f $(BINARIES)

# Pull in dependencies that already exist
-include $(OBJS:.o=.d)

%.o : %.cu
	nvcc -c $(MPI_CFLAGS) $(NVCC_CFLAGS) $(DEFS) $<
	nvcc -M $(MPI_CFLAGS) $(NVCC_CFLAGS) $(DEFS) $*.cu > $*.d

ifeq ($(XLC_COMPILER), $(YES))
%.o : %.cpp
	$(CC) -Mc $(CUDA_CFLAGS) $(DEFS) $<
else
%.o : %.cpp
	$(CC) -c $(CUDA_CFLAGS) $(DEFS) $<
	$(CC) -MM $(CUDA_CFLAGS) $(DEFS) $*.cpp > $*.d
endif
