#!/usr/bin/env bash


#export CUDA_VISIBLE_DEVICES=$SLURM_LOCALID
export CUDA_VISIBLE_DEVICES=$OMPI_COMM_WORLD_LOCAL_RANK

echo $CUDA_VISIBLE_DEVICES
./neko $1