#!/bin/bash

n=9
nn=0
while [ $nn -le $n ]; do
    mkdir $nn
    cp \
    /lustre/catchment/exps/GEOSldas_CN45_pso_g1_a0_a1_et_strm_camels_test2006_10_2_reset/$nn/run/timing.txt \
    ./$nn/
    cp \
    /lustre/catchment/exps/GEOSldas_CN45_pso_g1_a0_a1_et_strm_camels_test2006_10_2_reset/$nn/run/lenkf.j \
    ./$nn/
    nn=$((nn+1))
done

