//==================================================================
// Title:  Cuda x-drop seed-and-extend alignment algorithm
// Author: A. Zeni, G. Guidi
//==================================================================
#include "logan_functions.cuh"
#include "seed.cuh"
#include <chrono>

using namespace std;
using namespace chrono;

// GGGG: custom cuda allocator to use cudaMallocHost when allocating a std::vector
// If we don't allocate the host vector using cudaMallocHost, it creates an illegal memory access when moving data from device to host
// Given this interally uses cudaMallocHost, the size n of the std::vector must be defined, such as:
// std::vector<int, cuda_allocator<int>> vec(n)
template <typename T>
class cuda_allocator : public std::allocator<T> {
public:
  using pointer = typename std::allocator<T>::pointer;

  pointer allocate(std::size_t n) 
  {
    void* ptr;
    cudaError_t err = cudaMallocHost(&ptr, n * sizeof(T));
  
    // GGGG: throw an error and stop the computation if the size isn't defined since it'd create an illegal memory access	  	
    if (err != cudaSuccess)
    {
        std::cerr << "ERROR allocating memory on the host (missing size for cuda_allocator): " << cudaGetErrorString(err) << std::endl;
        throw std::bad_alloc();
    }  
    
    return static_cast<pointer>(ptr);
  }

  void deallocate(pointer p, std::size_t n) 
  {
    cudaFreeHost(p);
  }
};

// GGGG: function to copy a standard std::vector into one using cuda_allocator
template <typename T>
void copy_to_cuda_vector(const std::vector<T, std::allocator<T>>& src,
                         std::vector<T, cuda_allocator<T>>& dst)
{
  dst.resize(src.size());
  std::copy(src.begin(), src.end(), dst.begin());
}

#define cudaErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char* file, int line, bool abort = true){

	if(code != cudaSuccess){
		fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
	if(abort) exit(code);
	}
}

__inline__ __device__ void warpReduce(volatile short *input,
										  int myTId){
		input[myTId] = (input[myTId] > input[myTId + 32]) ? input[myTId] : input[myTId + 32]; 
		input[myTId] = (input[myTId] > input[myTId + 16]) ? input[myTId] : input[myTId + 16];
		input[myTId] = (input[myTId] > input[myTId + 8]) ? input[myTId] : input[myTId + 8]; 
		input[myTId] = (input[myTId] > input[myTId + 4]) ? input[myTId] : input[myTId + 4];
		input[myTId] = (input[myTId] > input[myTId + 2]) ? input[myTId] : input[myTId + 2];
		input[myTId] = (input[myTId] > input[myTId + 1]) ? input[myTId] : input[myTId + 1];
}

__inline__ __device__ short reduce_max(short *input, int dim, int n_threads){
	unsigned int myTId = threadIdx.x;   
	if(dim>32){
		for(int i = n_threads/2; i >32; i>>=1){
			if(myTId < i){
						input[myTId] = (input[myTId] > input[myTId + i]) ? input[myTId] : input[myTId + i];
			}__syncthreads();
		}//__syncthreads();
	}
	if(myTId<32)
		warpReduce(input, myTId);
	__syncthreads();
	return input[0];
}

__inline__ __device__ void updateExtendedSeedL(SeedL &seed,
					ExtensionDirectionL direction, //as there are only 4 directions we may consider even smaller data types
					int cols,
					int rows,
					int lowerDiag,
					int upperDiag)
{
	if (direction == EXTEND_LEFTL)
	{
		int beginDiag = seed.beginDiagonal;
		// Set lower and upper diagonals.
		
		if (getLowerDiagonal(seed) > beginDiag + lowerDiag)
			setLowerDiagonal(seed, beginDiag + lowerDiag);
		if (getUpperDiagonal(seed) < beginDiag + upperDiag)
			setUpperDiagonal(seed, beginDiag + upperDiag);

		// Set new start position of seed.
		seed.beginPositionH -= rows;
		seed.beginPositionV -= cols;
	} else {  // direction == EXTEND_RIGHTL
		// Set new lower and upper diagonals.
		int endDiag = seed.endDiagonal;
		if (getUpperDiagonal(seed) < endDiag - lowerDiag)
			setUpperDiagonal(seed, (endDiag - lowerDiag));
		if (getLowerDiagonal(seed) > (endDiag - upperDiag))
			setLowerDiagonal(seed, endDiag - upperDiag);

		// Set new end position of seed.
		seed.endPositionH += rows;
		seed.endPositionV += cols;
		
	}
}

__inline__ __device__ void computeAntidiag(short *antiDiag1,
									short *antiDiag2,
									short *antiDiag3,
									char* querySeg,
									char* databaseSeg,
									int &best,
									int &scoreDropOff,
									int &cols,
									int &rows,
									int &minCol,
									int &maxCol,
									int &antiDiagNo,
									int &offset1,
									int &offset2,
									ExtensionDirectionL direction,
									int n_threads
									){
	int tid = threadIdx.x;
	
	for(int i = 0; i < maxCol; i+=n_threads){

		int col = tid + minCol + i;
		int queryPos, dbPos;
		
		queryPos = col - 1;
		dbPos = col + rows - antiDiagNo - 1;

		if(col < maxCol){
		
			int tmp = max_logan(antiDiag2[col-offset2],antiDiag2[col-offset2-1]) + GAP_EXT;
		
			int score = (querySeg[queryPos] == databaseSeg[dbPos]) ? MATCH : MISMATCH;
			
			tmp = max_logan(antiDiag1[col-offset1-1]+score,tmp);
			
			antiDiag3[tid+1+i] = (tmp < best - scoreDropOff) ? UNDEF : tmp;
		
		}
	}
}

__inline__ __device__ void calcExtendedLowerDiag(int &lowerDiag,
			  int const &minCol,
			  int const &antiDiagNo)
{
	int minRow = antiDiagNo - minCol;
	if (minCol - minRow < lowerDiag)
		lowerDiag = minCol - minRow;
}

__inline__ __device__ void calcExtendedUpperDiag(int &upperDiag,
			  int const &maxCol,
			  int const &antiDiagNo)
{
	int maxRow = antiDiagNo + 1 - maxCol;
	if (maxCol - 1 - maxRow > upperDiag)
		upperDiag = maxCol - 1 - maxRow;
}

__inline__ __device__ void initAntiDiag3(short *antiDiag3,
						   int &a3size,
						   int const &offset,
						   int const &maxCol,
						   int const &antiDiagNo,
						   int const &minScore,
						   int const &gapCost,
						   int const &undefined)
{
	a3size = maxCol + 1 - offset;

	antiDiag3[0] = undefined;
	antiDiag3[maxCol - offset] = undefined;

	if (antiDiagNo * gapCost > minScore)
	{
		if (offset == 0) // init first column
			antiDiag3[0] = antiDiagNo * gapCost;
		if (antiDiagNo - maxCol == 0) // init first row
			antiDiag3[maxCol - offset] = antiDiagNo * gapCost;
	}
}

__inline__ __device__ void initAntiDiags(
			   short *antiDiag1,
			   short *antiDiag2,
			   short *antiDiag3,
			   int &a2size,
			   int &a3size,
			   int const &dropOff,
			   int const &gapCost,
			   int const &undefined)
{
	a2size = 1;

	antiDiag2[0] = 0;

	a3size = 2;

	antiDiag3[0] = gapCost;
	antiDiag3[1] = gapCost;
}

__global__ void extendSeedLGappedXDropOneDirectionGlobal(
		SeedL *seed,
		char *querySegArray,
		char *databaseSegArray,
		ExtensionDirectionL direction,
		int scoreDropOff,
		int *res,
		int *offsetQuery,
		int *offsetTarget,
		int offAntidiag,
		short *antidiag,
		int n_threads
		)
{
	int myId = blockIdx.x;
	int myTId = threadIdx.x;
	char *querySeg;
	char *databaseSeg;

	if(myId==0){
		querySeg = querySegArray;
		databaseSeg = databaseSegArray;
	}
	else{
		querySeg = querySegArray + offsetQuery[myId-1];
		databaseSeg = databaseSegArray + offsetTarget[myId-1];
	}

	short *antiDiag1 = &antidiag[myId*offAntidiag*3]; 
	short* antiDiag2 = &antiDiag1[offAntidiag];
		short* antiDiag3 = &antiDiag2[offAntidiag];


	SeedL mySeed(seed[myId]);	
	//dimension of the antidiagonals
	int a1size = 0, a2size = 0, a3size = 0;
	int cols, rows;

	if(myId == 0){
			cols = offsetQuery[myId]+1;
			rows = offsetTarget[myId]+1;
	}
	else{
			cols = offsetQuery[myId]-offsetQuery[myId-1]+1;
			rows = offsetTarget[myId]-offsetTarget[myId-1]+1;
	}

	if (rows == 1 || cols == 1)
		return;

	
	int minCol = 1;
	int maxCol = 2;

	int offset1 = 0; // number of leading columns that need not be calculated in antiDiag1
	int offset2 = 0; //                                                       in antiDiag2
	int offset3 = 0; //                                                       in antiDiag3

	initAntiDiags(antiDiag1,antiDiag2, antiDiag3, a2size, a3size, scoreDropOff, GAP_EXT, UNDEF);
	int antiDiagNo = 1; // the currently calculated anti-diagonal

	int best = 0; // maximal score value in the DP matrix (for drop-off calculation)

	int lowerDiag = 0;
	int upperDiag = 0;

	extern __shared__ short temp_alloc[];
	short *temp= &temp_alloc[0];

	while (minCol < maxCol)
	{	

		
		++antiDiagNo;

		//antidiagswap
		//antiDiag2 -> antiDiag1
		//antiDiag3 -> antiDiag2
		//antiDiag1 -> antiDiag3
		short *t = antiDiag1;
		antiDiag1 = antiDiag2;
		antiDiag2 = antiDiag3;
		antiDiag3 = t;
		int t_l = a1size;
		a1size = a2size;
		a2size = a3size;
		a3size = t_l;
		offset1 = offset2;
		offset2 = offset3;
		offset3 = minCol-1;
		
		initAntiDiag3(antiDiag3, a3size, offset3, maxCol, antiDiagNo, best - scoreDropOff, GAP_EXT, UNDEF);
		
		computeAntidiag(antiDiag1, antiDiag2, antiDiag3, querySeg, databaseSeg, best, scoreDropOff, cols, rows, minCol, maxCol, antiDiagNo, offset1, offset2, direction, n_threads);	 	
		//roofline analysis
		__syncthreads();	
	
		int tmp, antiDiagBest = UNDEF;	
		for(int i=0; i<a3size; i+=n_threads){
			int size = a3size-i;
			
			if(myTId<n_threads){
				temp[myTId] = (myTId<size) ? antiDiag3[myTId+i]:UNDEF;				
			}
			__syncthreads();
			
			tmp = reduce_max(temp,size, n_threads);
			antiDiagBest = (tmp>antiDiagBest) ? tmp:antiDiagBest;

		}
		best = (best > antiDiagBest) ? best : antiDiagBest;
		
		while (minCol - offset3 < a3size && antiDiag3[minCol - offset3] == UNDEF &&
			   minCol - offset2 - 1 < a2size && antiDiag2[minCol - offset2 - 1] == UNDEF)
		{
			++minCol;
		}

		// Calculate new maxCol
		while (maxCol - offset3 > 0 && (antiDiag3[maxCol - offset3 - 1] == UNDEF) &&
									   (antiDiag2[maxCol - offset2 - 1] == UNDEF))
		{
			--maxCol;
		}
		++maxCol;

		// Calculate new lowerDiag and upperDiag of extended seed
		calcExtendedLowerDiag(lowerDiag, minCol, antiDiagNo);
		calcExtendedUpperDiag(upperDiag, maxCol - 1, antiDiagNo);
		
		// end of databaseSeg reached?
		minCol = (minCol > (antiDiagNo + 2 - rows)) ? minCol : (antiDiagNo + 2 - rows);
		// end of querySeg reached?
		maxCol = (maxCol < cols) ? maxCol : cols;
		//}
	}

	int longestExtensionCol = a3size + offset3 - 2;
	int longestExtensionRow = antiDiagNo - longestExtensionCol;
	int longestExtensionScore = antiDiag3[longestExtensionCol - offset3];
	
	if (longestExtensionScore == UNDEF)
	{
		if (antiDiag2[a2size -2] != UNDEF)
		{
			// reached end of query segment
			longestExtensionCol = a2size + offset2 - 2;
			longestExtensionRow = antiDiagNo - 1 - longestExtensionCol;
			longestExtensionScore = antiDiag2[longestExtensionCol - offset2];
			
		}
		else if (a2size > 2 && antiDiag2[a2size-3] != UNDEF)
		{
			// reached end of database segment
			longestExtensionCol = a2size + offset2 - 3;
			longestExtensionRow = antiDiagNo - 1 - longestExtensionCol;
			longestExtensionScore = antiDiag2[longestExtensionCol - offset2];
			
		}
	}

	if (longestExtensionScore == UNDEF){

		// general case
		for (int i = 0; i < a1size; ++i){

			if (antiDiag1[i] > longestExtensionScore){

				longestExtensionScore = antiDiag1[i];
				longestExtensionCol = i + offset1;
				longestExtensionRow = antiDiagNo - 2 - longestExtensionCol;
			
			}
		}
	}
	
	if (longestExtensionScore != UNDEF)
		updateExtendedSeedL(mySeed, direction, longestExtensionCol, longestExtensionRow, lowerDiag, upperDiag);
	seed[myId] = mySeed;
	res[myId] = longestExtensionScore;

}

void extendSeedL(std::vector<SeedL> &seeds,
			ExtensionDirectionL direction,
			std::vector<std::string> &target,
			std::vector<std::string> &query,
			std::vector<ScoringSchemeL> &penalties,
			int const& XDrop,
			int const& kmer_length,
			int *res,
			int numAlignments,
			int ngpus,
			int n_threads,
		 	double& devicet,
			double& duration_device
			)
{

	// thread safe timer
	std::vector<double> tduration(ngpus, 0.0);

	// GGGG: std::vector<SeedL> &seeds needs to be allocated using pinned memory usign cudaMallocaHost
	// but I cannot call cudaMallocaHost in the non-cuda file where extendSeedL is called
	// so I'm going to create a copy of the vector to handle the moving back and forth from the GPU
	// then put the final results into the original seeds vector
	// the new vector uses a custom allocator defined at the top of this file
	
	std::vector<SeedL, cuda_allocator<SeedL>> cudaseeds(numAlignments);   // seeds vector using cudaMallocHost
	std::vector<SeedL, cuda_allocator<SeedL>> cudaseeds_r(numAlignments); // seeds vector using cudaMallocHost
	copy_to_cuda_vector(seeds, cudaseeds);
	copy_to_cuda_vector(seeds, cudaseeds_r);

	if(scoreGapExtend(penalties[0]) >= 0)
	{

		cout<<"Error: Logan does not support gap extension penalty >= 0\n";
		exit(-1);
	}
	if(scoreGapOpen(penalties[0]) >= 0)
	{

		cout<<"Error: Logan does not support gap opening penalty >= 0\n";
		exit(-1);
	}
	
	#ifdef ADAPTABLE
    	n_threads = (XDrop/WARP_DIM + 1)* WARP_DIM;
    	if(n_threads>1024)
        	n_threads=1024;
	#endif

	//declare streams
	cudaStream_t stream_r[MAX_GPUS], stream_l[MAX_GPUS];

	// NB nSequences is correlated to the number of GPUs that we have
	int nSequences = numAlignments/ngpus;
	int nSequencesLast = nSequences+numAlignments%ngpus;
	
	// GGGG: cudaMallocHost needed to pin memory on host for final result of the alignment
	int *scoreLeft = NULL;
	cudaMallocHost((void **) &scoreLeft, numAlignments * sizeof(int));

	int *scoreRight = NULL;
        cudaMallocHost((void **) &scoreRight, numAlignments * sizeof(int));

	//sequences offsets	 		
	vector<int> offsetLeftQ[MAX_GPUS];
	vector<int> offsetLeftT[MAX_GPUS];	
	vector<int> offsetRightQ[MAX_GPUS];	
	vector<int> offsetRightT[MAX_GPUS];

	//shared_mem_size per block per GPU
	int ant_len_left[MAX_GPUS];
	int ant_len_right[MAX_GPUS];

	//antidiag in case shared memory isn't enough
	short *ant_l[MAX_GPUS], *ant_r[MAX_GPUS];

	//total lenght of the sequences
	int totalLengthQPref[MAX_GPUS];
	int totalLengthTPref[MAX_GPUS];
	int totalLengthQSuff[MAX_GPUS];
	int totalLengthTSuff[MAX_GPUS];

	//declare and allocate sequences prefixes and suffixes
	char *prefQ[MAX_GPUS], *prefT[MAX_GPUS];
	char *suffQ[MAX_GPUS], *suffT[MAX_GPUS];

	//declare GPU offsets
	int *offsetLeftQ_d[MAX_GPUS], *offsetLeftT_d[MAX_GPUS];
	int *offsetRightQ_d[MAX_GPUS], *offsetRightT_d[MAX_GPUS];
	
	//declare GPU results
	int *scoreLeft_d[MAX_GPUS], *scoreRight_d[MAX_GPUS];

	//declare GPU seeds
	SeedL *seed_d_l[MAX_GPUS], *seed_d_r[MAX_GPUS];

	//declare prefixes and suffixes on the GPU  
	char *prefQ_d[MAX_GPUS], *prefT_d[MAX_GPUS];
	char *suffQ_d[MAX_GPUS], *suffT_d[MAX_GPUS];

	std::vector<double> pergpustime(ngpus);

#pragma omp parallel for num_threads(ngpus)
	for(int i = 0; i < ngpus; i++)
	{
		int dim = nSequences;
		
		if(i == ngpus-1)
			dim = nSequencesLast;
			
		//compute offsets and shared memory per block
		int MYTHREAD = omp_get_thread_num();
		auto start_setup_ithread = NOW;
		ant_len_left[i]=0;
		ant_len_right[i]=0;
		
		for(int j = 0; j < dim; j++){

			offsetLeftQ[i].push_back(getBeginPositionV(seeds[j+i*nSequences]));
			offsetLeftT[i].push_back(getBeginPositionH(seeds[j+i*nSequences]));
			ant_len_left[i] = std::max(std::min(offsetLeftQ[i][j],offsetLeftT[i][j]), ant_len_left[i]);
			
			offsetRightQ[i].push_back(query[j+i*nSequences].size()-getEndPositionV(seeds[j+i*nSequences]));
			offsetRightT[i].push_back(target[j+i*nSequences].size()-getEndPositionH(seeds[j+i*nSequences]));
			ant_len_right[i] = std::max(std::min(offsetRightQ[i][j], offsetRightT[i][j]), ant_len_right[i]);
		}
		
		//compute antidiagonal offsets
		partial_sum(offsetLeftQ[i].begin(),offsetLeftQ[i].end(),offsetLeftQ[i].begin());	
		partial_sum(offsetLeftT[i].begin(),offsetLeftT[i].end(),offsetLeftT[i].begin());
		partial_sum(offsetRightQ[i].begin(),offsetRightQ[i].end(),offsetRightQ[i].begin());
		partial_sum(offsetRightT[i].begin(),offsetRightT[i].end(),offsetRightT[i].begin());
		//set total length of the sequences
		totalLengthQPref[i] = offsetLeftQ[i][dim-1];
		totalLengthTPref[i] = offsetLeftT[i][dim-1];
		totalLengthQSuff[i] = offsetRightQ[i][dim-1];
		totalLengthTSuff[i] = offsetRightT[i][dim-1];
		//allocate sequences prefix and suffix on the CPU
		prefQ[i] = (char*)malloc(sizeof(char)*totalLengthQPref[i]);
		prefT[i] = (char*)malloc(sizeof(char)*totalLengthTPref[i]);
		suffQ[i] = (char*)malloc(sizeof(char)*totalLengthQSuff[i]);
		suffT[i] = (char*)malloc(sizeof(char)*totalLengthTSuff[i]);
		//generate prefix and suffix on the CPU
		reverse_copy(query[0+i*nSequences].c_str(),query[0+i*nSequences].c_str()+offsetLeftQ[i][0],prefQ[i]);

		memcpy(prefT[i], target[0+i*nSequences].c_str(), offsetLeftT[i][0]);
		memcpy(suffQ[i], query[0+i*nSequences].c_str()+getEndPositionV(seeds[0+i*nSequences]), offsetRightQ[i][0]);
		reverse_copy(target[0+i*nSequences].c_str()+getEndPositionH(seeds[0+i*nSequences]),target[0+i*nSequences].c_str()+getEndPositionH(seeds[0+i*nSequences])+offsetRightT[i][0],suffT[i]);
		
		for(int j = 1; j < dim; j++)
		{
			char *seqptr = prefQ[i] + offsetLeftQ[i][j-1];
			reverse_copy(query[j+i*nSequences].c_str(),query[j+i*nSequences].c_str()+(offsetLeftQ[i][j]-offsetLeftQ[i][j-1]),seqptr);
			
			seqptr = prefT[i] + offsetLeftT[i][j-1];
			memcpy(seqptr, target[j+i*nSequences].c_str(), offsetLeftT[i][j]-offsetLeftT[i][j-1]);
			seqptr = suffQ[i] + offsetRightQ[i][j-1];
			memcpy(seqptr, query[j+i*nSequences].c_str()+getEndPositionV(seeds[j+i*nSequences]), offsetRightQ[i][j]-offsetRightQ[i][j-1]);
			seqptr = suffT[i] + offsetRightT[i][j-1];
			reverse_copy(target[j+i*nSequences].c_str()+getEndPositionH(seeds[j+i*nSequences]),target[j+i*nSequences].c_str()+getEndPositionH(seeds[j+i*nSequences])+(offsetRightT[i][j]-offsetRightT[i][j-1]),seqptr);

		}
		
		auto end_setup_ithread = NOW;
		duration<double> setup_ithread = end_setup_ithread - start_setup_ithread;
		pergpustime[MYTHREAD] = setup_ithread.count();
	}
	auto start_outer_c = NOW;
#pragma omp parallel for num_threads(ngpus)
	for(int i = 0; i < ngpus; i++)
	{
		int dim = nSequences;
		if(i == ngpus-1)
			dim = nSequencesLast;
			
		//set gpu device
		cudaSetDevice(i);
		//create streams
		cudaStreamCreateWithFlags(&stream_r[i],cudaStreamNonBlocking);
		cudaStreamCreateWithFlags(&stream_l[i],cudaStreamNonBlocking);
		//allocate antidiagonals on the GPU
        	cudaErrchk(cudaMalloc(&ant_l[i], sizeof(short)*ant_len_left[i]*3*dim));
        	cudaErrchk(cudaMalloc(&ant_r[i], sizeof(short)*ant_len_right[i]*3*dim));
		//allocate offsets on the GPU
		cudaErrchk(cudaMalloc(&offsetLeftQ_d[i], dim*sizeof(int)));
		cudaErrchk(cudaMalloc(&offsetLeftT_d[i], dim*sizeof(int)));
		cudaErrchk(cudaMalloc(&offsetRightQ_d[i], dim*sizeof(int)));
		cudaErrchk(cudaMalloc(&offsetRightT_d[i], dim*sizeof(int)));
		//allocate results on the GPU
		cudaErrchk(cudaMalloc(&scoreLeft_d[i], dim*sizeof(int)));
		cudaErrchk(cudaMalloc(&scoreRight_d[i], dim*sizeof(int)));
		//allocate seeds on the GPU
		cudaErrchk(cudaMalloc(&seed_d_l[i], dim*sizeof(SeedL)));
		cudaErrchk(cudaMalloc(&seed_d_r[i], dim*sizeof(SeedL)));
		//allocate sequences on the GPU
		cudaErrchk(cudaMalloc(&prefQ_d[i], totalLengthQPref[i]*sizeof(char)));
		cudaErrchk(cudaMalloc(&prefT_d[i], totalLengthTPref[i]*sizeof(char)));
		cudaErrchk(cudaMalloc(&suffQ_d[i], totalLengthQSuff[i]*sizeof(char)));
		cudaErrchk(cudaMalloc(&suffT_d[i], totalLengthTSuff[i]*sizeof(char)));
		//copy seeds on the GPU
		cudaErrchk(cudaMemcpyAsync(seed_d_l[i], &cudaseeds[0]+i*nSequences, dim*sizeof(SeedL), cudaMemcpyHostToDevice, stream_l[i]));
		cudaErrchk(cudaMemcpyAsync(seed_d_r[i], &cudaseeds_r[0]+i*nSequences, dim*sizeof(SeedL), cudaMemcpyHostToDevice, stream_r[i]));
		//copy offsets on the GPU
		cudaErrchk(cudaMemcpyAsync(offsetLeftQ_d[i], &offsetLeftQ[i][0], dim*sizeof(int), cudaMemcpyHostToDevice, stream_l[i]));
		cudaErrchk(cudaMemcpyAsync(offsetLeftT_d[i], &offsetLeftT[i][0], dim*sizeof(int), cudaMemcpyHostToDevice, stream_l[i]));
		cudaErrchk(cudaMemcpyAsync(offsetRightQ_d[i], &offsetRightQ[i][0], dim*sizeof(int), cudaMemcpyHostToDevice, stream_r[i]));
		cudaErrchk(cudaMemcpyAsync(offsetRightT_d[i], &offsetRightT[i][0], dim*sizeof(int), cudaMemcpyHostToDevice, stream_r[i]));
		//copy sequences on the GPU
		cudaErrchk(cudaMemcpyAsync(prefQ_d[i], prefQ[i], totalLengthQPref[i]*sizeof(char), cudaMemcpyHostToDevice, stream_l[i]));
		cudaErrchk(cudaMemcpyAsync(prefT_d[i], prefT[i], totalLengthTPref[i]*sizeof(char), cudaMemcpyHostToDevice, stream_l[i]));
		cudaErrchk(cudaMemcpyAsync(suffQ_d[i], suffQ[i], totalLengthQSuff[i]*sizeof(char), cudaMemcpyHostToDevice, stream_r[i]));
		cudaErrchk(cudaMemcpyAsync(suffT_d[i], suffT[i], totalLengthTSuff[i]*sizeof(char), cudaMemcpyHostToDevice, stream_r[i]));
	}
	
	auto start_c = NOW;
	
	//  main kernel execution
#pragma omp parallel for num_threads(ngpus)
	for(int i = 0; i < ngpus;i++)
	{
		cudaSetDevice(i);
		
		int dim = nSequences;
		if(i == ngpus-1)
			dim = nSequencesLast;
		
		extendSeedLGappedXDropOneDirectionGlobal <<<dim, n_threads, n_threads*sizeof(short), stream_l[i]>>> (seed_d_l[i], prefQ_d[i], prefT_d[i], EXTEND_LEFTL, XDrop, scoreLeft_d[i], offsetLeftQ_d[i], offsetLeftT_d[i], ant_len_left[i], ant_l[i], n_threads);
		extendSeedLGappedXDropOneDirectionGlobal <<<dim, n_threads, n_threads*sizeof(short), stream_r[i]>>> (seed_d_r[i], suffQ_d[i], suffT_d[i], EXTEND_RIGHTL, XDrop, scoreRight_d[i], offsetRightQ_d[i], offsetRightT_d[i], ant_len_right[i], ant_r[i], n_threads);
		
	}
	
	

#pragma omp parallel for num_threads(ngpus)
	for(int i = 0; i < ngpus; i++)
	{
		cudaSetDevice(i);
		cudaDeviceSynchronize();
	}
	
	auto end_c = NOW;
	
	duration<double> compute = end_c - start_c;
	devicet += compute.count();
	

#pragma omp parallel for num_threads(ngpus)
	for(int i = 0; i < ngpus; i++)
	{
		cudaSetDevice(i);
		int dim = nSequences;
		
		if(i == ngpus-1)
			dim = nSequencesLast;
			
		cudaErrchk(cudaMemcpyAsync(scoreLeft+i*nSequences, scoreLeft_d[i], dim*sizeof(int), cudaMemcpyDeviceToHost, stream_l[i]));
		cudaErrchk(cudaMemcpyAsync(&cudaseeds[0]+i*nSequences, seed_d_l[i], dim*sizeof(SeedL), cudaMemcpyDeviceToHost,stream_l[i]));
		cudaErrchk(cudaMemcpyAsync(scoreRight+i*nSequences, scoreRight_d[i], dim*sizeof(int), cudaMemcpyDeviceToHost, stream_r[i]));
		cudaErrchk(cudaMemcpyAsync(&cudaseeds_r[0]+i*nSequences, seed_d_r[i], dim*sizeof(SeedL), cudaMemcpyDeviceToHost,stream_r[i]));
	
	}

	cudaErrchk(cudaPeekAtLastError());

#pragma omp parallel for num_threads(ngpus)
	for(int i = 0; i < ngpus; i++)
	{
		cudaSetDevice(i);

		cudaStreamDestroy(stream_l[i]);
		cudaStreamDestroy(stream_r[i]);
		free(prefQ[i]);
		free(prefT[i]);
		free(suffQ[i]);
		free(suffT[i]);
		cudaErrchk(cudaFree(prefQ_d[i]));
		cudaErrchk(cudaFree(prefT_d[i]));
		cudaErrchk(cudaFree(suffQ_d[i]));
		cudaErrchk(cudaFree(suffT_d[i]));
		cudaErrchk(cudaFree(offsetLeftQ_d[i]));
		cudaErrchk(cudaFree(offsetLeftT_d[i]));
		cudaErrchk(cudaFree(offsetRightQ_d[i]));
		cudaErrchk(cudaFree(offsetRightT_d[i]));
		cudaErrchk(cudaFree(seed_d_l[i]));
		cudaErrchk(cudaFree(seed_d_r[i]));
		cudaErrchk(cudaFree(scoreLeft_d[i]));
		cudaErrchk(cudaFree(scoreRight_d[i]));
		cudaErrchk(cudaFree(ant_l[i])); 
		cudaErrchk(cudaFree(ant_r[i]));

	}
	auto end_f = NOW;
	
	// GGGG: copy results and extensions back to seeds (the regular std::vector, not using cuda_allocator)
	for(int i = 0; i < numAlignments; i++)
	{
		res[i] = scoreLeft[i] + scoreRight[i] + kmer_length;
		
		setBeginPositionH(seeds[i], getBeginPositionH(cudaseeds[i]));  // left extension wasn't modified before but now we need to move back to seeds from cudaseeds
		setBeginPositionV(seeds[i], getBeginPositionV(cudaseeds[i]));  // left extension wasn't modified before but now we need to move back to seeds from cudaseeds
		setEndPositionH(seeds[i], getEndPositionH(cudaseeds_r[i]));    
		setEndPositionV(seeds[i], getEndPositionV(cudaseeds_r[i]));
	}
	
	cudaFreeHost(scoreLeft);
	cudaFreeHost(scoreRight);
	auto end_outer_c = NOW;
	duration<double> compute_outer = end_outer_c - start_outer_c;
	duration_device += compute_outer.count();
}

