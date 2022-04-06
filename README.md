# Flettner Rotor

This repository contains all the parts necessary to run the Flettner rotor case at Re=30,000.  

It contains two different case files, one for the production run and one for the scaling and power measruements.

# Installation
First, the mesh needs to be decompressed 
```gzip -d rot_cyl.nmsh.gz```

Then, the executable needs to be compiled, for this part Neko needs to have been installed with the appropriate backend support.
```
git clone -b v0.3.1 https://github.com/ExtremeFLOW/neko.git
cd neko
./regen.sh
```
The backend support is chosen when configuring.
For CUDA:
```
./configure --prefix=/path/to/neko_install --with-cuda=/path/to/cuda 
```
For HIP:
```
./configure --prefix=/path/to/neko_install --with-hip=/path/to/hip
```
For CPU:
```
./configure --prefix=/path/to/neko_install
```
Then make the install
```
make install -j32
```

Move to the root of this directory and execute

```
/path/to/neko_install/bin/makeneko rot_cyl.f90
```

this yields an executable `neko`.

# Running
Please note that the case is quite large and requires around 2TB of RAM. The scaling tests can be run with 

```
mpirun ./run.sh rot_cyl_scale.case
```
If using srun instead, please change the comented line in `run.sh/run_power.sh`.
Power measruements for the GPUs are made with
```
mpirun ./run_power.sh rot_cyl_scale.case
```
For AMD, switch nvidia-smi to rocm-smi in `run_power.sh`.

To make the simulation run, you can run it according to:
```
mpirun ./run.sh rot_cyl_sim.case
```





