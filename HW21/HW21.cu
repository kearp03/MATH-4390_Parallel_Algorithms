// Name: Kyle Earp
// Optimizing nBody GPU code more. 
// nvcc HW21.cu -o temp -lglut -lm -lGLU -lGL -use_fast_math

/*
 What to do:
 This is some lean n-body code that runs on the GPU for any number of bodies (within reason).
 It has been optimized using standard techniques like shared memory, using float4s, setting the block sizes to powers of 2, 
 and ensuring that the number of bodies is an exact multiple of the block size to reduce if statement.
 Take this code and make it run as fast as possible using any tricks you know or can find.
 Try to keep the general format the same so we can time it and compare it with others' code.
 This will be a competition. 
 You can remove all the restrictions from the blocks. We will be competing with 10,752 bodies. 
 Note: The code takes two arguments as inputs:
 1. The number of bodies to simulate.
 2. Whether to draw sub-arrangements of the bodies during the simulation (1), or only the first and last arrangements (0).
*/

/*
 What was done:
 Check to see if the block size was a power of 2.
 Checked to see if N could be divided evenly by the block size.
 Checked to see if 256 < N < 262,144.
 Used shared memory in the force kernal.
*/

// Assumes mass of 1.0 for all bodies.

// Include files
#include <GL/glut.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>

// Defines
#define BLOCK_SIZE 128
#define PI 3.14159265359
#define DRAW_RATE 10

// This is to create a Lennard-Jones type function G/(r^p) - H(r^q). (p < q) p has to be less than q.
// In this code we will keep it a p = 2 and q = 4 problem. The diameter of a body is found using the general
// case so it will be more robust but in the code leaving it as a set 2, 4 problem make the coding much easier.
#define G 10.0f
#define H 10.0f
#define LJP  2.0
#define LJQ  4.0

#define DT 0.0001f
#define RUN_TIME 1.0
#define DAMP 0.5f

// Globals
int N, DrawFlag;
float4 *P, *V, *F;
float4 *PGPU, *VGPU, *FGPU;
float GlobeRadius, Diameter, Radius;
dim3 BlockSize;
dim3 GridSize;

// Function prototypes
void cudaErrorCheck(const char *, int);
void keyPressed(unsigned char, int, int);
long elaspedTime(struct timeval, struct timeval);
void drawPicture();
void timer();
void setup();
__global__ void getForces(float4 *, float4 *);
__global__ void initialMoveBodies(float4 *, float4 *, float4 *);
__global__ void moveBodies(float4 *, float4 *, float4 *);
void nBody();
int main(int, char**);

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

void keyPressed(unsigned char key, int x, int y)
{
	if(key == 's')
	{
		printf("\n The simulation is running.\n");
		timer();
	}
	
	if(key == 'q')
	{
		exit(0);
	}
}

// Calculating elasped time.
long elaspedTime(struct timeval start, struct timeval end)
{
	// tv_sec = number of seconds past the Unix epoch 01/01/1970
	// tv_usec = number of microseconds past the current second.
	
	long startTime = start.tv_sec * 1000000 + start.tv_usec; // In microseconds.
	long endTime = end.tv_sec * 1000000 + end.tv_usec; // In microseconds

	// Returning the total time elasped in microseconds
	return endTime - startTime;
}

void drawPicture()
{
	int i;
	
	glClear(GL_COLOR_BUFFER_BIT);
	glClear(GL_DEPTH_BUFFER_BIT);
	
	cudaMemcpyAsync(P, PGPU, N*sizeof(float4), cudaMemcpyDeviceToHost);
	cudaErrorCheck(__FILE__, __LINE__);
	
	glColor3d(1.0,1.0,0.5);
	for(i=0; i<N; i++)
	{
		glPushMatrix();
		glTranslatef(P[i].x, P[i].y, P[i].z);
		glutSolidSphere(Radius,20,20);
		glPopMatrix();
	}
	
	glutSwapBuffers();
}

void timer()
{	
	timeval start, end;
	long computeTime;
	
	drawPicture();
	gettimeofday(&start, NULL);
    	nBody();
    	cudaDeviceSynchronize();
		cudaErrorCheck(__FILE__, __LINE__);
	gettimeofday(&end, NULL);
	drawPicture();
    	
	computeTime = elaspedTime(start, end);
	printf("\n The compute time was %ld microseconds.\n\n", computeTime);
}

void setup()
{
    float randomAngle1, randomAngle2, randomRadius;
    float d, dx, dy, dz;
    int test;
    	
    BlockSize.x = BLOCK_SIZE;
	BlockSize.y = 1;
	BlockSize.z = 1;
	
	GridSize.x = (N - 1)/BlockSize.x + 1; //Makes enough blocks to deal with the whole vector.
	GridSize.y = 1;
	GridSize.z = 1;
	
	// Making sure N is a multiple of the block size so we do not have to check if we are working past N.
	// Then making sure N is in the range stated above.
	if(N%BlockSize.x != 0)
	{
		printf("\n Your number of bodies %d does not evenly divide the block size of %d, this code will not work.", N, BlockSize.x);
		printf("\n Reset the number of bodies you want to simulate and try again.");
		printf("\n Good Bye\n");
		exit(0);
	}

    P = (float4*)malloc(N*sizeof(float4));
    V = (float4*)malloc(N*sizeof(float4));
    F = (float4*)malloc(N*sizeof(float4));
    
	cudaMalloc(&PGPU,N*sizeof(float4));
	cudaErrorCheck(__FILE__, __LINE__);
	cudaMalloc(&VGPU,N*sizeof(float4));
	cudaErrorCheck(__FILE__, __LINE__);
	cudaMalloc(&FGPU,N*sizeof(float4));
	cudaErrorCheck(__FILE__, __LINE__);
    	
	Diameter = pow(H/G, 1.0/(LJQ - LJP)); // This is the value where the force is zero for the L-J type force.
	Radius = Diameter/2.0;
	
	// Using the radius of a body and a 68% packing ratio to find the radius of a global sphere that should hold all the bodies.
	// Then we double this radius just so we can get all the bodies setup with no problems. 
	float totalVolume = float(N)*(4.0/3.0)*PI*Radius*Radius*Radius;
	totalVolume /= 0.68;
	float totalRadius = pow(3.0*totalVolume/(4.0*PI), 1.0/3.0);
	GlobeRadius = 2.0*totalRadius;
	
	// Randomly setting these bodies in the glaobal sphere and setting the initial velosity, inotial force, and mass.
	for(int i = 0; i < N; i++)
	{
		test = 0;
		while(test == 0)
		{
			// Get random position.
			randomAngle1 = ((float)rand()/(float)RAND_MAX)*2.0*PI;
			randomAngle2 = ((float)rand()/(float)RAND_MAX)*PI;
			randomRadius = ((float)rand()/(float)RAND_MAX)*GlobeRadius;
			P[i].x = randomRadius*cos(randomAngle1)*sin(randomAngle2);
			P[i].y = randomRadius*sin(randomAngle1)*sin(randomAngle2);
			P[i].z = randomRadius*cos(randomAngle2);
			
			// Making sure the balls centers are at least a diameter apart.
			// If they are not throw these positions away and try again.
			test = 1;
			for(int j = 0; j < i; j++)
			{
				dx = P[i].x-P[j].x;
				dy = P[i].y-P[j].y;
				dz = P[i].z-P[j].z;
				d = sqrt(dx*dx + dy*dy + dz*dz);
				if(d < Diameter)
				{
					test = 0;
					break;
				}
			}
		}
	
		V[i].x = 0.0;
		V[i].y = 0.0;
		V[i].z = 0.0;
		
		F[i].x = 0.0;
		F[i].y = 0.0;
		F[i].z = 0.0;
	}
	
	cudaMemcpyAsync(PGPU, P, N*sizeof(float4), cudaMemcpyHostToDevice);
	cudaErrorCheck(__FILE__, __LINE__);
	cudaMemcpyAsync(VGPU, V, N*sizeof(float4), cudaMemcpyHostToDevice);
	cudaErrorCheck(__FILE__, __LINE__);
	cudaMemcpyAsync(FGPU, F, N*sizeof(float4), cudaMemcpyHostToDevice);
	cudaErrorCheck(__FILE__, __LINE__);
	
	printf("\n To start timing type s.\n");
}

__global__ void getForces(float4* p, float4 *f)
{
	float dx, dy, dz,invd,invd2;
	float force_mag;
	__shared__ float4 p_sh[BLOCK_SIZE];
	
	int i = threadIdx.x + blockDim.x*blockIdx.x;
	
	float4 p_i = p[i];
	float4 f_i = make_float4(0.0, 0.0, 0.0, 0.0);
	float4 p_j;
	
	for(int k = 0; k < gridDim.x; k++)
	{
		p_sh[threadIdx.x] = p[threadIdx.x + k*blockDim.x];
		__syncthreads();
		
		if(k == blockIdx.x)
		{
			#pragma unroll 16
			for(int j = 0; j < threadIdx.x; j++)
			{
				p_j = p_sh[j];
				dx = p_j.x - p_i.x;
				dy = p_j.y - p_i.y;
				dz = p_j.z - p_i.z;
				invd2 = 1.0f/(dx*dx + dy*dy + dz*dz);
				invd = sqrt(invd2);
				
				force_mag  = (G)*(invd2) - (H)*(invd2*invd2);
				f_i.x += force_mag*dx*invd;
				f_i.y += force_mag*dy*invd;
				f_i.z += force_mag*dz*invd;
			}
			#pragma unroll 16
			for(int j = threadIdx.x + 1; j < blockDim.x; j++)
			{
				p_j = p_sh[j];
				dx = p_j.x - p_i.x;
				dy = p_j.y - p_i.y;
				dz = p_j.z - p_i.z;
				invd2 = 1.0f/(dx*dx + dy*dy + dz*dz);
				invd = sqrt(invd2);
				
				force_mag  = (G)*(invd2) - (H)*(invd2*invd2);
				f_i.x += force_mag*dx*invd;
				f_i.y += force_mag*dy*invd;
				f_i.z += force_mag*dz*invd;
			}
		}
		else
		{
			#pragma unroll 128
			for(int j = 0; j < blockDim.x; j++)
			{
				p_j = p_sh[j];
				dx = p_j.x - p_i.x;
				dy = p_j.y - p_i.y;
				dz = p_j.z - p_i.z;
				invd2 = 1.0f/(dx*dx + dy*dy + dz*dz);
				invd = sqrt(invd2);

				force_mag  = (G)*(invd2) - (H)*(invd2*invd2);
				f_i.x += force_mag*dx*invd;
				f_i.y += force_mag*dy*invd;
				f_i.z += force_mag*dz*invd;
			}
		}
		__syncthreads();
	}

	f[i] = f_i;
}

__global__ void initialMoveBodies(float4 *p, float4 *v, float4 *f)
{
	int i = threadIdx.x + blockDim.x*blockIdx.x;
	float4 p_i = p[i];
	float4 v_i = v[i];
	float4 f_i = f[i];
	
	v_i.x += (f_i.x-DAMP*v_i.x)*0.5f*DT;
	v_i.y += (f_i.y-DAMP*v_i.y)*0.5f*DT;
	v_i.z += (f_i.z-DAMP*v_i.z)*0.5f*DT;

	p_i.x += v_i.x*DT;
	p_i.y += v_i.y*DT;
	p_i.z += v_i.z*DT;

	p[i] = p_i;
	v[i] = v_i;
}

__global__ void moveBodies(float4 *p, float4 *v, float4 *f)
{	
	int i = threadIdx.x + blockDim.x*blockIdx.x;
	float4 p_i = p[i];
	float4 v_i = v[i];
	float4 f_i = f[i];

	v_i.x += (f_i.x-DAMP*v_i.x)*DT;
	v_i.y += (f_i.y-DAMP*v_i.y)*DT;
	v_i.z += (f_i.z-DAMP*v_i.z)*DT;

	p_i.x += v_i.x*DT;
	p_i.y += v_i.y*DT;
	p_i.z += v_i.z*DT;

	p[i] = p_i;
	v[i] = v_i;
}

void nBody()
{
	int    drawCount = 0; 
	float  t = 0.0;

	getForces<<<GridSize,BlockSize>>>(PGPU, FGPU);
	cudaErrorCheck(__FILE__, __LINE__);
	initialMoveBodies<<<GridSize,BlockSize>>>(PGPU, VGPU, FGPU);
	cudaErrorCheck(__FILE__, __LINE__);
	t += DT;
	drawCount++;

	while(t < RUN_TIME)
	{
		getForces<<<GridSize,BlockSize>>>(PGPU, FGPU);
		cudaErrorCheck(__FILE__, __LINE__);
		moveBodies<<<GridSize,BlockSize>>>(PGPU, VGPU, FGPU);
		cudaErrorCheck(__FILE__, __LINE__);
		if(drawCount == DRAW_RATE) 
		{
			if(DrawFlag) 
			{	
				drawPicture();
			}
			drawCount = 0;
		}
		
		t += DT;
		drawCount++;
	}
}

int main(int argc, char** argv)
{
	if(argc < 3)
	{
		printf("\n You need to enter the number of bodies (an int)"); 
		printf("\n and if you want to draw the bodies as they move (1 draw, 0 don't draw),");
		printf("\n on the comand line.\n"); 
		exit(0);
	}
	else
	{
		N = atoi(argv[1]);
		DrawFlag = atoi(argv[2]);
	}
	
	setup();
	
	int XWindowSize = 1000;
	int YWindowSize = 1000;
	
	glutInit(&argc,argv);
	glutInitDisplayMode(GLUT_DOUBLE | GLUT_DEPTH | GLUT_RGB);
	glutInitWindowSize(XWindowSize,YWindowSize);
	glutInitWindowPosition(0,0);
	glutCreateWindow("nBody Test");
	GLfloat light_position[] = {1.0, 1.0, 1.0, 0.0};
	GLfloat light_ambient[]  = {0.0, 0.0, 0.0, 1.0};
	GLfloat light_diffuse[]  = {1.0, 1.0, 1.0, 1.0};
	GLfloat light_specular[] = {1.0, 1.0, 1.0, 1.0};
	GLfloat lmodel_ambient[] = {0.2, 0.2, 0.2, 1.0};
	GLfloat mat_specular[]   = {1.0, 1.0, 1.0, 1.0};
	GLfloat mat_shininess[]  = {10.0};
	glClearColor(0.0, 0.0, 0.0, 0.0);
	glShadeModel(GL_SMOOTH);
	glColorMaterial(GL_FRONT, GL_AMBIENT_AND_DIFFUSE);
	glLightfv(GL_LIGHT0, GL_POSITION, light_position);
	glLightfv(GL_LIGHT0, GL_AMBIENT, light_ambient);
	glLightfv(GL_LIGHT0, GL_DIFFUSE, light_diffuse);
	glLightfv(GL_LIGHT0, GL_SPECULAR, light_specular);
	glLightModelfv(GL_LIGHT_MODEL_AMBIENT, lmodel_ambient);
	glMaterialfv(GL_FRONT, GL_SPECULAR, mat_specular);
	glMaterialfv(GL_FRONT, GL_SHININESS, mat_shininess);
	glEnable(GL_LIGHTING);
	glEnable(GL_LIGHT0);
	glEnable(GL_COLOR_MATERIAL);
	glEnable(GL_DEPTH_TEST);
	glutKeyboardFunc(keyPressed);
	glutDisplayFunc(drawPicture);
	
	float4 eye = {0.0f, 0.0f, 2.0f*GlobeRadius};
	float near = 0.2;
	float far = 5.0*GlobeRadius;
	
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glFrustum(-0.2, 0.2, -0.2, 0.2, near, far);
	glMatrixMode(GL_MODELVIEW);
	glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
	gluLookAt(eye.x, eye.y, eye.z, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0);
	
	glutMainLoop();
	return 0;
}