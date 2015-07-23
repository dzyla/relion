#ifndef CUDA_UTILS_CUH_
#define CUDA_UTILS_CUH_

#include <cuda_runtime.h>
#include "src/gpu_utils/cuda_settings.h"
#include <stdio.h>
#include <signal.h>
#include <vector>

#ifdef CUDA_DOUBLE_PRECISION
#define FLOAT double
__device__ inline FLOAT cuda_atomic_add(double* address, double val)
{
	unsigned long long int* address_as_ull = (unsigned long long int*)address;
	unsigned long long int old = *address_as_ull, assumed;
	do
	{
		assumed = old;
		old = atomicCAS(address_as_ull, assumed, __double_as_longlong(val + __longlong_as_double(assumed)));
	}
	while (assumed != old); // Note: uses integer comparison to avoid hang in case of NaN (since NaN != NaN)
	return __longlong_as_double(old);
}
#else
#define FLOAT float
__device__ inline void cuda_atomic_add(float* address, float value)
{
  atomicAdd(address,value);
}
#endif

#ifdef DEBUG_CUDA
#define HANDLE_ERROR( err ) (HandleError( err, __FILE__, __LINE__ ))
#else
#define HANDLE_ERROR( err ) (err) //Do nothing
#endif
static void HandleError( cudaError_t err, const char *file, int line )
{
    if (err != cudaSuccess)
    {
        printf( "DEBUG_ERROR: %s in %s at line %d\n",
        		cudaGetErrorString( err ), file, line );
		raise(SIGSEGV);
    }
}

template< typename T>
static inline void cudaCpyHostToDevice( T* h_ptr, T* d_ptr, size_t size)
{
	HANDLE_ERROR(cudaMemcpy( d_ptr, h_ptr, size * sizeof(T), cudaMemcpyHostToDevice));
};

template< typename T>
static inline void cudaCpyHostToDevice( T* h_ptr, T* d_ptr, size_t size, cudaStream_t stream)
{
	HANDLE_ERROR(cudaMemcpyAsync( d_ptr, h_ptr, size * sizeof(T), cudaMemcpyHostToDevice, stream));
};

template< typename T>
static inline void cudaCpyDeviceToHost( T* d_ptr, T* h_ptr, size_t size)
{
	HANDLE_ERROR(cudaMemcpy( h_ptr, d_ptr, size * sizeof(T), cudaMemcpyDeviceToHost));
};

template< typename T>
static inline void cudaCpyDeviceToHost( T* d_ptr, T* h_ptr, size_t size, cudaStream_t stream)
{
	HANDLE_ERROR(cudaMemcpyAsync( h_ptr, d_ptr, size * sizeof(T), cudaMemcpyDeviceToHost, stream));
};

/**
 * Print cuda device memory info
 */
static void cudaPrintMemInfo()
{
	size_t free;
	size_t total;
	HANDLE_ERROR(cudaMemGetInfo( &free, &total ));
	float free_hr(free/(1024.*1024.));
	float total_hr(total/(1024.*1024.));
    printf( "free %.2fMiB, total %.2fMiB, used %.2fMiB\n",
    		free_hr, total_hr, total_hr - free_hr);
}

template <typename T>
class CudaGlobalPtr
{
public:
	size_t size; //Size used when copying data from and to device
	T *h_ptr, *d_ptr; //Host and device pointers
	bool h_do_free, d_do_free; //True if host or device needs to be freed

	inline
	__host__ CudaGlobalPtr<T>():
		size(0), h_ptr(0), d_ptr(0), h_do_free(false), d_do_free(false)
	{};

	inline
	__host__ CudaGlobalPtr<T>(size_t size):
		size(size), h_ptr(new T[size]), d_ptr(0), h_do_free(true), d_do_free(false)
	{};

	inline
	__host__ CudaGlobalPtr<T>(T * h_start, size_t size):
		size(size), h_ptr(h_start), d_ptr(0), h_do_free(false), d_do_free(false)
	{};

	inline
	__host__ CudaGlobalPtr<T>(T * h_start, T * d_start, size_t size):
		size(size), h_ptr(h_start), d_ptr(d_start), h_do_free(false), d_do_free(false)
	{};

	/**
	 * Allocate memory on device
	 */
	inline
	__host__ void device_alloc()
	{
#ifdef DEBUG_CUDA
		if (d_do_free)
			printf("DEBUG_WARNING: Device double allocation.\n");
#endif
		d_do_free = true;
		HANDLE_ERROR(cudaMalloc( (void**) &d_ptr, size * sizeof(T)));
	}

	/**
	 * Allocate memory on device with given size
	 */
	inline
	__host__ void device_alloc(size_t newSize)
	{
		size = newSize;
		device_alloc();
	}

	/**
	 * Allocate memory on host
	 */
	inline
	__host__ void host_alloc()
	{
#ifdef DEBUG_CUDA
		if (h_do_free)
			printf("DEBUG_WARNING: Host double allocation.\n");
#endif
		h_do_free = true;
		h_ptr = new T[size];
	}

	/**
	 * Initiate device memory with provided value
	 */
	inline
	__host__ void device_init(int value)
	{
#ifdef DEBUG_CUDA
		if (d_ptr == 0)
			printf("DEBUG_WARNING: Memset requested before allocation in device_init().\n");
#endif
		HANDLE_ERROR(cudaMemset( d_ptr, value, size * sizeof(T)));
	}

	/**
	 * Copy a number (size) of bytes to device stored in the host pointer
	 */
	inline
	__host__ void cp_to_device()
	{
#ifdef DEBUG_CUDA
		if (d_ptr == 0)
			printf("DEBUG_WARNING: cp_to_device() called before allocation.\n");
		if (h_ptr == 0)
			printf("DEBUG_WARNING: NULL host pointer in cp_to_device().\n");
#endif
		cudaCpyHostToDevice<T>(h_ptr, d_ptr, size);
	}

	/**
	 * Copy a number (size) of bytes to device stored in the provided host pointer
	 */
	inline
	__host__ void cp_to_device(T * hostPtr)
	{
#ifdef DEBUG_CUDA
		if (h_ptr != 0)
			printf("DEBUG_WARNING: Host pointer already set in call to cp_to_device(hostPtr).\n");
#endif
		h_ptr = hostPtr;
		cp_to_device();
	}

	/**
	 * alloc and copy
	 */
	inline
	__host__ void put_on_device()
	{
		device_alloc();
		cp_to_device();
	}

	/**
	 * alloc size and copy
	 */
	inline
	__host__ void put_on_device(size_t newSize)
	{
		size=newSize;
		device_alloc();
		cp_to_device();
	}


	/**
	 * Copy a number (size) of bytes from device to the host pointer
	 */
	inline
	__host__ void cp_to_host()
	{
#ifdef DEBUG_CUDA
		if (d_ptr == 0)
			printf("DEBUG_WARNING: cp_to_host() called before allocation.\n");
		if (h_ptr == 0)
			printf("DEBUG_WARNING: NULL host pointer in cp_to_host().\n");
#endif
		cudaCpyDeviceToHost<T>(d_ptr, h_ptr, size);
	}

	/**
	 * Host data quick access
	 */
	inline
	__host__ T& operator[](size_t idx) { return h_ptr[idx]; };


	/**
	 * Host data quick access
	 */
	inline
	__host__ const T& operator[](size_t idx) const { return h_ptr[idx]; };

	/**
	 * Device pointer quick access
	 */
	inline
	__host__ T* operator~() {
#ifdef DEBUG_CUDA
		if (d_ptr == 0)
			printf("DEBUG_WARNING: \"kernel cast\" on null pointer.\n");
#endif
		return d_ptr;
	};

	/**
	 * Delete device data
	 */
	inline
	__host__ void free_device()
	{
#ifdef DEBUG_CUDA
		if (d_ptr == 0)
			printf("DEBUG_WARNING: Free device memory was called on NULL pointer in free_device().\n");
#endif
		d_do_free = false;
		HANDLE_ERROR(cudaFree(d_ptr));
		d_ptr = 0;
	}

	/**
	 * Delete host data
	 */
	inline
	__host__ void free_host()
	{
#ifdef DEBUG_CUDA
		if (h_ptr == 0)
		{
			printf("DEBUG_ERROR: free_host() called on NULL pointer.\n");
	        exit( EXIT_FAILURE );
		}
#endif
		h_do_free = false;
		delete [] h_ptr;
		h_ptr = 0;
	}

	/**
	 * Delete both device and host data
	 */
	inline
	__host__ void free()
	{
		free_device();
		free_host();
	}

	inline
	__host__ ~CudaGlobalPtr()
	{
		if (d_do_free) free_device();
		if (h_do_free) free_host();
	}
};

class IndexedDataArrayMask
{
public:
	// indexes of job partition
	//   every element in jobOrigin    is a reference to point to a position in a IndexedDataArray.weights array where that job starts RELATIVE to firstPos
	//   every element in jobExtent    specifies the number of weights for that job
	CudaGlobalPtr<long unsigned> jobOrigin, jobExtent;

	long unsigned firstPos, lastPos; // positions in indexedDataArray data and index arrays to slice out
	long unsigned weightNum, jobNum; // number of weights and jobs this class

	inline
	__host__  IndexedDataArrayMask():
	jobOrigin(),
	jobExtent(),
	firstPos(),
	lastPos(),
	weightNum(),
	jobNum()
	{};

public:

	__host__ void setNumberOfJobs(long int newSize)
	{
		jobNum=newSize;
		jobOrigin.size=newSize;
		jobExtent.size=newSize;
	}

	__host__ void setNumberOfWeights(long int newSize)
	{
		weightNum=newSize;
	}

	inline
	__host__  ~IndexedDataArrayMask()
	{
//		jobOrigin.free_host();
//		jobExtent.free_host();
	};
};

class IndexedDataArray
{
public:
	//actual data
	CudaGlobalPtr<FLOAT> weights;

	// indexes with same length as data
	// -- basic indices ---------------------------------
	//     rot_id  = id of rot     = which of all POSSIBLE orientations                               this weight signifies
	//     rot_idx = index of rot  = which in the sequence of the determined significant orientations this weight signifies
	//   trans_id  = id of trans   = which of all POSSIBLE translations                               this weight signifies
	//   class_id  = id of class   = which of all POSSIBLE classes                                    this weight signifies
	// -- special indices ---------------------------------
	//   ihidden_overs  =  mapping to MWeight-based indexing for compatibility
	CudaGlobalPtr<long unsigned> rot_id, rot_idx, trans_idx, ihidden_overs, class_id;

	inline
	__host__  IndexedDataArray():
		weights(),
		rot_id(),
		rot_idx(),
		trans_idx(),
		ihidden_overs(),
		class_id()
	{};

	// constructor which takes a parent IndexedDataArray and a mask to create a child
	inline
	__host__  IndexedDataArray(IndexedDataArray &parent, IndexedDataArrayMask &mask):
		weights(		&(parent.weights.h_ptr[mask.firstPos])		,&(parent.weights.d_ptr[mask.firstPos])			,mask.weightNum),
		rot_id(			&(parent.rot_id.h_ptr[mask.firstPos])		,&(parent.rot_id.d_ptr[mask.firstPos])			,mask.weightNum),
		rot_idx(		&(parent.rot_idx.h_ptr[mask.firstPos])		,&(parent.rot_idx.d_ptr[mask.firstPos])			,mask.weightNum),
		trans_idx(		&(parent.trans_idx.h_ptr[mask.firstPos])	,&(parent.trans_idx.d_ptr[mask.firstPos])		,mask.weightNum),
		ihidden_overs(	&(parent.ihidden_overs.h_ptr[mask.firstPos]),&(parent.ihidden_overs.d_ptr[mask.firstPos])	,mask.weightNum),
		class_id(		&(parent.class_id.h_ptr[mask.firstPos])		,&(parent.class_id.d_ptr[mask.firstPos])		,mask.weightNum)
	{
		weights.d_do_free=false;
		rot_id.d_do_free=false;
		rot_idx.d_do_free=false;
		trans_idx.d_do_free=false;
		ihidden_overs.d_do_free=false;
		class_id.d_do_free=false;

		weights.h_do_free=false;
		rot_id.h_do_free=false;
		rot_idx.h_do_free=false;
		trans_idx.h_do_free=false;
		ihidden_overs.h_do_free=false;
		class_id.h_do_free=false;
	};

public:

	__host__ void setDataSize(long int newSize)
	{
		weights.size=newSize;
		rot_id.size=newSize;
		rot_idx.size=newSize;
		trans_idx.size=newSize;
		ihidden_overs.size=newSize;
		class_id.size=newSize;
	}

	__host__ void dual_alloc_all()
	{
		weights.host_alloc();
		rot_id.host_alloc();
		rot_idx.host_alloc();
		trans_idx.host_alloc();
		ihidden_overs.host_alloc();
		class_id.host_alloc();
		//-----------------------
		weights.device_alloc();
		rot_id.device_alloc();
		rot_idx.device_alloc();
		trans_idx.device_alloc();
		ihidden_overs.device_alloc();
		class_id.device_alloc();
	}
};


class ProjectionParams
{

public:
	std::vector< long unsigned > orientation_num; 					// the number of significant orientation for each class
	long unsigned orientationNumAllClasses;							// sum of the above
	std::vector< double > rots, tilts, psis;
	std::vector< long unsigned > iorientclasses, iover_rots;

	// These are arrays which detial the number of entries in each class, and where each class starts.
	// NOTE: There is no information about which class each class_idx refers to, there is only
	// a distinction between different classes.
	std::vector< long unsigned > class_entries, class_idx;
	inline
	__host__ ProjectionParams():

		rots(),
		tilts(),
		psis(),
		iorientclasses(),
		iover_rots(),

		class_entries(),
		class_idx(),
		orientation_num(),
		orientationNumAllClasses(0)

	{};

	inline
	__host__ ProjectionParams(unsigned long classes):

		rots(),
		tilts(),
		psis(),
		iorientclasses(),
		iover_rots(),

		class_entries(classes),
		class_idx(classes),
		orientation_num(classes),
		orientationNumAllClasses(0)
	{
		class_idx[0]=0;
		class_entries[0]=0;
	};


	// constructor that slices out a part of a parent ProjectionParams, assumed to contain a single (partial or entire) class
	inline
	__host__ ProjectionParams(ProjectionParams &parent, unsigned long start, unsigned long end):
		rots(			&parent.rots[start],  			&parent.rots[end]),
		tilts(			&parent.tilts[start], 			&parent.tilts[end]),
		psis(			&parent.psis[start],  			&parent.psis[end]),
		iorientclasses( &parent.iorientclasses[start],  &parent.iorientclasses[end]),
		iover_rots(		&parent.iover_rots[start],  	&parent.iover_rots[end]),
		orientation_num(1),
		class_entries(1,end-start),
		class_idx(1,0) // NOTE: this is NOT the class, but rather where in these partial PrjParams to start, which is @ 0.
	{};

public:
	// Appends new values into the projection parameters for later use.
	// class_idx is used as such:
	// the n:th class (beginning with 0:th)
	// begins @ element class_idx[n]
	// ends   @ element class_idx[n]+class_entries[n]

	__host__ void pushBackAll(long unsigned iclass, double NEWrot,double NEWtilt ,double NEWpsi, long unsigned NEWiorientclasses,long unsigned NEWiover_rots)
	{
		// incremement the counter for this class
		class_entries[iclass]++;
		// and push a new entry
		rots.push_back(NEWrot);
		tilts.push_back(NEWtilt);
		psis.push_back(NEWpsi);
		iorientclasses.push_back(NEWiorientclasses);
		iover_rots.push_back(NEWiover_rots);
	}
};
#endif

