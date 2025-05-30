// Name: Kyle Earp
// Histogram useing atomics in global memory and shared memory.
// nvcc HW13.cu -o temp

/*
 What to do:
 This code generates a series of random numbers and places them into bins based on size ranges using the CPU. 
 Create a binning scheme that utilizes the GPU and takes advantage of both global and shared atomics. 
 The function call has already been created. Additionally, make the block size twice the number of multiprocessors.
*/

// Include files
#include <sys/time.h>
#include <stdio.h>

//Length of vectors to be added. Max int value is 2,147,483,647
//Chat said that the length of the sequence of random number that srand generates is 2^32
//That is 4,294,967,296 this is bigger than the largest int but the max for an unsigned int.
// Defines
#define NUMBER_OF_RANDOM_NUMBERS 2147483
#define NUMBER_OF_BINS 10
#define MAX_RANDOM_NUMBER 100.0f

// Global variables
float *RandomNumbersGPU;
int *HistogramGPU;
float *RandomNumbersCPU;
int *HistogramCPU;
int *HistogramCPUTemp; // Use it to hod the GPU histogram past back so we can compair to CPU histogram.
dim3 BlockSize; //This variable will hold the Dimensions of your block
dim3 GridSize; //This variable will hold the Dimensions of your grid

//Function prototypes
void cudaErrorCheck(const char *, int);
void SetUpCudaDevices();
void AllocateMemory();
void Initialize();
void CleanUp();
void fillHistogramCPU();
__global__ void fillHistogramGPU(float *, int *);
int main();

// This check to see if an error happened in your CUDA code. It tell you what it thinks went wrong,
// and what file and line it occured on.
void cudaErrorCheck(const char *file, int line)
{
	cudaError_t  error;
	error = cudaGetLastError();

	if(error != cudaSuccess)
	{
		printf("\n CUDA ERROR: message = %s, File = %s, Line = %d\n", cudaGetErrorString(error), file, line);
		exit(0);
	}
}

//This will be the layout of the parallel space we will be using.
void SetUpCudaDevices()
{
	cudaDeviceProp prop;
	cudaGetDeviceProperties(&prop, 0);
	cudaErrorCheck(__FILE__, __LINE__);
	
	BlockSize.x = prop.multiProcessorCount*2; //Change the block size to be twice the number of multiprocessors.
	if(prop.maxThreadsDim[0] < BlockSize.x)
	{
		printf("\n You are trying to create more threads (%d) than your GPU can suppport on a block (%d).\n Good Bye\n", BlockSize.x, prop.maxThreadsDim[0]);
		exit(0);
	}
	BlockSize.y = 1;
	BlockSize.z = 1;
	
	GridSize.x = (NUMBER_OF_RANDOM_NUMBERS - 1)/BlockSize.x + 1; //Makes enough blocks to deal with the whole vector.
	if(prop.maxGridSize[0] < GridSize.x)
	{
		printf("\n You are trying to create more blocks (%d) than your GPU can suppport (%d).\n Good Bye\n", GridSize.x, prop.maxGridSize[0]);
		exit(0);
	}
	GridSize.y = 1;
	GridSize.z = 1;
}

//Sets memory on the GPU and CPU for our use.
void AllocateMemory()
{					
	//Allocate Device (GPU) Memory
	cudaMalloc(&RandomNumbersGPU, NUMBER_OF_RANDOM_NUMBERS*sizeof(float));
	cudaErrorCheck(__FILE__, __LINE__);
	cudaMalloc(&HistogramGPU, NUMBER_OF_BINS*sizeof(int));
	cudaErrorCheck(__FILE__, __LINE__);

	//Allocate Host (CPU) Memory
	RandomNumbersCPU = (float*)malloc(NUMBER_OF_RANDOM_NUMBERS*sizeof(float));
	HistogramCPU = (int*)malloc(NUMBER_OF_BINS*sizeof(int));
	HistogramCPUTemp = (int*)malloc(NUMBER_OF_BINS*sizeof(int));
	
	//Setting the the histograms to zero.
	cudaMemset(HistogramGPU, 0, NUMBER_OF_BINS*sizeof(int));
	cudaErrorCheck(__FILE__, __LINE__);
	memset(HistogramCPU, 0, NUMBER_OF_BINS*sizeof(int));
}

//Loading random numbers.
void Initialize()
{
	time_t t;
	srand((unsigned) time(&t));
	
	for(int i = 0; i < NUMBER_OF_RANDOM_NUMBERS; i++)
	{		
		RandomNumbersCPU[i] = MAX_RANDOM_NUMBER*(float)rand()/RAND_MAX;	
	}
}

//Cleaning up memory after we are finished.
void CleanUp()
{
	cudaFree(RandomNumbersGPU); 
	cudaErrorCheck(__FILE__, __LINE__);
	cudaFree(HistogramGPU);
	cudaErrorCheck(__FILE__, __LINE__);
	free(RandomNumbersCPU); 
	free(HistogramCPU);
	free(HistogramCPUTemp);
	//printf("\n Cleanup Done.");
}

void fillHistogramCPU()
{
	float breakPoint;
	int k, done;
	float stepSize = MAX_RANDOM_NUMBER/(float)NUMBER_OF_BINS;
	
	for(int i = 0; i < NUMBER_OF_RANDOM_NUMBERS; i++)
	{
		breakPoint = stepSize;
		k = 0;
		done =0;
		while(done == 0)
		{
			if(RandomNumbersCPU[i] < breakPoint)
			{
				HistogramCPU[k]++; 
				done = 1;
			}
			
			if(NUMBER_OF_BINS < k)
			{
				printf("\n k is too big\n");
				exit(0);
			}
			k++;
			breakPoint += stepSize;
		}
	}
}

//This is the kernel. It is the function that will run on the GPU.
__global__ void fillHistogramGPU(float *randomNumbers, int *hist)
{
	float breakPoint;
	int k, done;
	float stepSize = MAX_RANDOM_NUMBER/(float)NUMBER_OF_BINS;

	__shared__ int histTemp[NUMBER_OF_BINS];

	int id = threadIdx.x + blockIdx.x*blockDim.x;
	
	// Zero out the shared memory, for loop is for the case where the number of bins is greater than the block size.
	for(int i = threadIdx.x; i < NUMBER_OF_BINS; i += blockDim.x)
	{
		histTemp[i] = 0;
	}
	
	__syncthreads();
	
	// Fill the shared memory with the histogram values. Only access the global memory if the id is less than the number of random numbers.
	if(id < NUMBER_OF_RANDOM_NUMBERS)
	{
		float randomNumber = randomNumbers[id];

		breakPoint = stepSize;
		k = 0;
		done = 0;
		while(done == 0)
		{
			if(randomNumber < breakPoint)
			{
				atomicAdd(&histTemp[k], 1);
				done = 1;
			}
			
			if(NUMBER_OF_BINS < k)
			{
				printf("\n k is too big\n");
				return;
			}
			k++;
			breakPoint += stepSize;
		}
	}

	__syncthreads();

	// Copy the shared memory to the global memory. For loop is for the case where the number of bins is greater than the block size.
	for(int i = threadIdx.x; i < NUMBER_OF_BINS; i += blockDim.x)
	{
		atomicAdd(&hist[i], histTemp[i]);
	}
	// if(threadIdx.x < NUMBER_OF_BINS)
	// {
	// 	atomicAdd(&hist[threadIdx.x], histTemp[threadIdx.x]);
	// }
}

int main()
{
	float time;
	timeval start, end;
	
	long int test = NUMBER_OF_RANDOM_NUMBERS;
	if(2147483647 < test)
	{
		printf("\nThe length of your vector is longer than the largest integer value allowed of 2,147,483,647.\n");
		printf("You should check your code.\n Good Bye\n");
		exit(0);
	}
	
	//Set the thread structure that you will be using on the GPU	
	SetUpCudaDevices();

	//Partitioning off the memory that you will be using and padding with zero vector will be a factor of block size.
	AllocateMemory();

	//Loading up values to be added.
	Initialize();
	
	gettimeofday(&start, NULL);
	fillHistogramCPU();
	gettimeofday(&end, NULL);
	time = (end.tv_sec * 1000000 + end.tv_usec) - (start.tv_sec * 1000000 + start.tv_usec);
	printf("\nTime on CPU = %.15f milliseconds\n", (time/1000.0));
	
	gettimeofday(&start, NULL);
	//Copy Memory from CPU to GPU		
	cudaMemcpyAsync(RandomNumbersGPU, RandomNumbersCPU, NUMBER_OF_RANDOM_NUMBERS*sizeof(float), cudaMemcpyHostToDevice);
	cudaErrorCheck(__FILE__, __LINE__);
	fillHistogramGPU<<<GridSize,BlockSize>>>(RandomNumbersGPU, HistogramGPU);
	cudaErrorCheck(__FILE__, __LINE__);
	//Copy Memory from GPU to CPU	
	cudaMemcpyAsync(HistogramCPUTemp, HistogramGPU, NUMBER_OF_BINS*sizeof(int), cudaMemcpyDeviceToHost);
	cudaErrorCheck(__FILE__, __LINE__);
	gettimeofday(&end, NULL);
	time = (end.tv_sec * 1000000 + end.tv_usec) - (start.tv_sec * 1000000 + start.tv_usec);
	printf("\nTime on GPU = %.15f milliseconds\n", (time/1000.0));
	
	//Check
	int absoluteDifference = 0;
	for(int i = 0; i < NUMBER_OF_BINS; i++)
	{
		printf("\n Difference in histogram bins %d is %d.", i, abs(HistogramCPUTemp[i] - HistogramCPU[i]));
		absoluteDifference += abs(HistogramCPUTemp[i] - HistogramCPU[i]);
	}
	printf("\n\n The absolute difference between the CPU and GPU histograms is %d.\n", absoluteDifference);

	//You're done so cleanup your mess.
	CleanUp();	
	
	printf("\n\n");
	return(0);
}
