rm -f temp
nvcc HW26.cu -o temp -lglut -lGLU -lGL
./temp