#!/bin/bash

n=29
nn=0
while [ $nn -le $n ]; do
    mkdir $nn
    cp \
    /lustre/catchment/exps/GEOSldas_CN45_pso_g1_a0_a1_et_strm_camels_test2006_30_test/$nn/run/timing.txt \
    ./$nn/
    cp \
    /lustre/catchment/exps/GEOSldas_CN45_pso_g1_a0_a1_et_strm_camels_test2006_30_test/$nn/run/lenkf.j \
    ./$nn/
    nn=$((nn+1))
done

