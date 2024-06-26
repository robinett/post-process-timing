#!/bin/csh -f

# GEOSldas job script ("lenkf" = Land Ensemble Kalman Filter)
#
# usage: lenkf.j [-debug]

#######################################################################
#                     Batch Parameters for Run Job
#######################################################################

#SBATCH --output=../scratch/GEOSldas_log_txt
#SBATCH --error=../scratch/GEOSldas_err_txt
#SBATCH --account=s2641
#SBATCH --time=02:00:00
#SBATCH --nodes=1 --ntasks-per-node=8
#SBATCH --job-name=18

#SBATCH --mail-user=trobinet@stanford.edu
#SBATCH --mail-type=END
#SBATCH --partition=catch-m6a4xl-demand
#######################################################################
#    System Settings and Architecture Specific Environment Variables
#######################################################################



module purge
source /efs/userhome/trobinet/.bashrc

echo $PATH
echo $LD_LIBRARY_PATH

umask 022
limit stacksize unlimited
setenv ARCH `uname`

setenv EXPID      18
setenv EXPDOMAIN  SMAP_EASEv2_M36
setenv EXPDIR     /lustre/catchment/exps/GEOSldas_CN45_pso_g1_a0_a1_et_strm_camels_test2006_30_test/$EXPID
setenv ESMADIR    $EXPDIR/build/
setenv GEOSBIN    $ESMADIR/bin/
# need to unsetenv LD_LIBRARY_PATH for execution of LDAS within the coupled land-atm DAS
#unsetenv LD_LIBRARY_PATH

set debug_flag = 0
if ( "$1" == "-debug" ) then
  set debug_flag = 1
endif
unset argv
setenv argv

#source $GEOSBIN/g5_modules

setenv I_MPI_DAPL_UD enable

# By default, ensure 0-diff across processor architecture by limiting MKL's freedom to pick algorithms.
# As of June 2021, MKL_CBWR=AVX2 is fastest setting that works for both haswell and skylake at NCCS.
# Change to MKL_CBWR=AUTO for fastest execution at the expense of results becoming processor-dependent.
#setenv MKL_CBWR "COMPATIBLE"
#setenv MKL_CBWR "AUTO"
setenv MKL_CBWR "AVX2"

#setenv LD_LIBRARY_PATH ${LD_LIBRARY_PATH}:${BASEDIR}/${ARCH}/lib
# reversed sequence for LADAS_COUPLING (Sep 2020)  (needed when coupling with ADAS using different BASEDIR)
setenv LD_LIBRARY_PATH ${BASEDIR}/${ARCH}/lib:${ESMADIR}/lib:${LD_LIBRARY_PATH} 

if ( -e /etc/os-release ) then
  module load nco/4.8.1
else
  module load other/nco-4.6.8-gcc-5.3-sp3
endif
setenv RUN_CMD "$GEOSBIN/esma_mpirun -np "

#######################################################################
#             Experiment Specific Environment Variables
#######################################################################

setenv    HOMDIR         $EXPDIR/run/
setenv    SCRDIR         $EXPDIR/scratch
setenv    MODEL          catchcnclm45
setenv    MYNAME         `finger $USER | cut -d: -f3 | head -1`
setenv    POSTPROC_HIST  1

# LADAS_COUPLING : 0 -- stand-alone LDAS (no coupling to ADAS)
#                : 1 -- LDAS coupled to central (deterministic) component of ADAS
#                : 2 -- LDAS coupled to atmospheric ensemble component of ADAS

setenv    LADAS_COUPLING   0
setenv    ENSEMBLE_FORCING NO

set NENS = `grep NUM_LDAS_ENSEMBLE:  $HOMDIR/LDAS.rc | cut -d':' -f2`
set END_DATE  = `grep     END_DATE:  $HOMDIR/CAP.rc | cut -d':' -f2`
set NUM_SGMT  = `grep     NUM_SGMT:  $HOMDIR/CAP.rc | cut -d':' -f2`
set BEG_DATE  = `grep     BEG_DATE:  $HOMDIR/CAP.rc | cut -d':' -f2`

echo 'testing two example commands that will run slow later to geth their time' >> $HOMDIR/timing.txt
echo 'the command: /lustre/catchment/bin_2/echo test.this.file | rev | cut -d'.' -f2 | rev' >> $HOMDIR/timing.txt
echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo test.this.file | rev | cut -d'.' -f2 | rev`
echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo test.this.file | cut -c1-4`
# let's echo the hostname
echo 'hostname' >> $HOMDIR/timing.txt
echo `hostname` >> $HOMDIR/timing.txt
# lets echo the date
echo 'date at start of pre-processing' >> $HOMDIR/timing.txt
echo `date` >> $HOMDIR/timing.txt

####################################################################### 
#  if LADAS_COUPLING==2, compute ens avg of atmens forcing 
####################################################################### 

#echo `date +"%T.%3N"`

if ( $LADAS_COUPLING == 2 && $ENSEMBLE_FORCING == "NO" ) then
   cd $HOMDIR
   set force_in  = $ADAS_EXPDIR
   set force_out = `grep MET_PATH: $HOMDIR/LDAS.rc | cut -d ':' -f2`
   python  $GEOSBIN/average_ensemble_forcing.py $force_in $force_out $NENS 
endif

/bin/rm -f $HOMDIR/lenkf_job_completed.txt 

#######################################################################
#                   Set Experiment Run Parameters
#######################################################################

#######################################################################
#        Move to Scratch Directory and Copy .rc .nml .rst files
#######################################################################

if (! -e $SCRDIR            ) mkdir -p $SCRDIR
cd $SCRDIR
/bin/rm -rf *.*
/bin/cp     $HOMDIR/cap_restart .
/bin/cp -f  $HOMDIR/*.rc .
/bin/cp -f  $HOMDIR/*.nml .

set LSMCHOICE = `grep -n -m 1 "LSM_CHOICE" $HOMDIR/LDAS.rc | cut -d':' -f3`

if( ${LSMCHOICE} > 1 ) then # CatchCN Only
    ln -s /shared/fake_forcing/CO2_MonthlyMean_DiurnalCycle.nc4
    ln -s /shared/fake_forcing/FPAR_CDF_Params-M09.nc4
endif

#######################################################################
# if $LADAS_COUPLING == 1:  LDAS coupled to central ADAS simulation
#######################################################################

if ( $LADAS_COUPLING == 1 ) then

   if ( $ENSEMBLE_FORCING == "YES" ) then

      # create perturbed forcing from central simulation and atm ensemble

      # python should come with ESMA_env g5_modules
      #module load python/GEOSpyD/Ana2019.03_py3.7
      set forcgrid = `grep GEOSldas.GRIDNAME LDAS.rc | cut -d':' -f2 | awk '{print $1}'`
      setenv GRID $forcgrid
      $GEOSBIN/enpert_forc.csh
      cd $SCRDIR
   else

      # copy central-simulation forcing from $FVWORK to scratch dir

      echo "copying lfo_Nx+- met forcing from $FVWORK to $SCRDIR"
      /bin/cp -f $FVWORK/*lfo_Nx+-*nc4  $SCRDIR/.

   endif
endif

#######################################################################
#              Create HISTORY Collection Directories
#######################################################################
   
set collections = ''
foreach line ("`cat HISTORY.rc`")
   set firstword  = `echo $line | awk '{print $1}'`
   set firstchar  = `echo $firstword | cut -c1`
   set secondword = `echo $line | awk '{print $2}'`

   if ( $firstword == "::" ) goto done

   if ( $firstchar != "#" ) then
      set collection  = `echo $firstword | sed -e "s/'//g"`
      set collections = `echo $collections $collection`
      if ( $secondword == :: ) goto done
   endif

   if ( $firstword == COLLECTIONS: ) then
      set collections = `echo $secondword | sed -e "s/'//g"`
   endif
end

done:

@ n_c = 0 
if ($POSTPROC_HIST > 0) then
   foreach ThisCol ($collections)
      set ref_t = `cat HISTORY.rc | grep ${ThisCol}.ref_time: | cut -d':' -f2 | cut -d',' -f1`
      if ( $ref_t != '000000' ) then
         echo ${ThisCol}.ref_time should be '000000'
         @ n_c = $n_c + 1
      endif
   end
endif
if ($n_c >= 1) then
   exit
endif

#######################################################################
#                      Domain Decomposition
#######################################################################
set npes_nx = `grep NX: LDAS.rc | cut -d':' -f2 `
set npes_ny = `grep NY: LDAS.rc | cut -d':' -f2 `
@ numprocs = $npes_nx * $npes_ny
if( -e IMS.rc ) then
   set oldtasks = `head -n 1 IMS.rc`
   if($numprocs != $oldtasks) then
      $GEOSBIN/preprocess_ldas.x optimize ../input/tile.data $numprocs nothing nothing nothing
   endif
endif

if( -e JMS.rc ) then
   set oldtasks = `head -n 1 JMS.rc | cut -c1-5`
   if($numprocs != $oldtasks) then
      $GEOSBIN/preprocess_ldas.x optimize ../input/tile.data $numprocs nothing nothing nothing
   endif
endif

set gridname = `grep GEOSldas.GRIDNAME LDAS.rc | cut -d':' -f2 | cut -d'-'  -f2 | awk '{print $1}'`
if ( "$gridname" == "CF" ) then
   set new_ny = `echo "NY:  "$numprocs`
   sed -i "/NY:/c\\$new_ny" LDAS.rc
else
   set new_nx = `echo "NX:  "$numprocs`
   sed -i "/NX:/c\\$new_nx" LDAS.rc
endif

#######################################################################
#         Create Strip Utility to Remove Multiple Blank Spaces
#######################################################################

set      FILE = strip
/bin/rm $FILE
cat << EOF > $FILE
#!/bin/ksh
/bin/mv \$1 \$1.tmp
touch   \$1
while read line
do
echo \$line >> \$1
done < \$1.tmp
exit
EOF
chmod +x $FILE

##### CHECK IF PSO FILES HAVE ALREADY BEEN CREATED #####
# write the .txt file that says that his one is done
# read ens_num.txt to get the ensemble number
set this_ens=`cat $HOMDIR/ens_num.txt`
echo "this_ens" >> $HOMDIR/PSO_iterations.txt
echo $this_ens >> $HOMDIR/PSO_iterations.txt

if ($this_ens == 0) then
  if ( -f $EXPDIR/../positions.csv ) then
    echo pso_exists
  else
    python3 $HOMDIR/main.py $EXPDIR
  endif
endif

##################################################################
######
######         Perform multiple iterations of Model Run
######
##################################################################

@ counter    = 1
while ( $counter <= ${NUM_SGMT} )

   /bin/rm -f  EGRESS.ldas
   /bin/cp -f $HOMDIR/CAP.rc .
   ./strip            CAP.rc
   
   # Set Time Variables for Current_(c), Ending_(e), and Segment_(s) dates 
   # ---------------------------------------------------------------------
   set nymdc = `cat cap_restart | cut -c1-8`
   set nhmsc = `cat cap_restart | cut -c10-15`
   set nymde = `cat CAP.rc | grep END_DATE:     | cut -d: -f2 | cut -c2-9`
   set nhmse = `cat CAP.rc | grep END_DATE:     | cut -d: -f2 | cut -c11-16`
   set nymds = `cat CAP.rc | grep JOB_SGMT:     | cut -d: -f2 | cut -c2-9`
   set nhmss = `cat CAP.rc | grep JOB_SGMT:     | cut -d: -f2 | cut -c11-16`
   
   # Compute Time Variables at the Finish_(f) of current segment
   # -----------------------------------------------------------
   set nyear   = `echo $nymds | cut -c1-4`
   set nmonth  = `echo $nymds | cut -c5-6`
   set nday    = `echo $nymds | cut -c7-8`
   set nhour   = `echo $nhmss | cut -c1-2`
   set nminute = `echo $nhmss | cut -c3-4`
   set nsec    = `echo $nhmss | cut -c5-6`
          @ dt = $nsec + 60 * $nminute + 3600 * $nhour + 86400 * $nday
   
   set nymdf = $nymdc
   set nhmsf = $nhmsc
   set date  = `$GEOSBIN/tick $nymdf $nhmsf $dt`
   set nymdf =  $date[1]
   set nhmsf =  $date[2]
   set year  = `echo $nymdf | cut -c1-4`
   set month = `echo $nymdf | cut -c5-6`
   set day   = `echo $nymdf | cut -c7-8`
   
        @  month = $month + $nmonth
   while( $month > 12 )
        @  month = $month - 12
        @  year  = $year  + 1
   end
        @  year  = $year  + $nyear
        @ nymdf  = $year * 10000 + $month * 100 + $day
   
   if( $nymdf >  $nymde )    set nymdf = $nymde
   if( $nymdf == $nymde )    then
       if( $nhmsf > $nhmse ) set nhmsf = $nhmse
   endif
   
   set yearc = `echo $nymdc | cut -c1-4`
   set yearf = `echo $nymdf | cut -c1-4`
   
   # Prescribed LAI/SAI for CATCHCN
   # -------------------------------
   
   set PRESCRIBE_DVG = `grep PRESCRIBE_DVG LDAS.rc | cut -d':' -f2`
   if( ${PRESCRIBE_DVG} == 3 ) then
       set FCSTDATE = `grep FCAST_BEGTIME  $HOMDIR/LDAS.rc | cut -d':' -f2`
       if( `echo $FCSTDATE | cut -d' ' -f1` == "" ) then
           set CAPRES = `cat cap_restart`
           set CAPRES1 = `echo $CAPRES | cut -d' ' -f1`
           set CAPRES2 = `echo $CAPRES | cut -d' ' -f2`
           set CAPRES = 'FCAST_BEGTIME: '`echo $CAPRES1``echo $CAPRES2`
           echo $CAPRES >> $HOMDIR/LDAS.rc
           /bin/cp -p $HOMDIR/LDAS.rc .
       endif
   endif
   
   if( ${PRESCRIBE_DVG} >= 1 ) then
   
       # Modify local CAP.rc Ending date if Finish time exceeds Current year boundary
       # ----------------------------------------------------------------------------
    
       if( $yearf > $yearc ) then
          @ yearf = $yearc + 1
          @ nymdf = $yearf * 10000 + 0101
           set oldstring = `cat CAP.rc | grep END_DATE:`
           set newstring = "END_DATE: $nymdf $nhmsf"
           /bin/mv CAP.rc CAP.tmp
           cat CAP.tmp | sed -e "s?$oldstring?$newstring?g" > CAP.rc
       endif
   
       # Creaate VEGDATA FIle Links
       # --------------------------
   
       if( ${PRESCRIBE_DVG} == 1 ) set VEGYR = $yearc
       if( ${PRESCRIBE_DVG} >= 2 ) set VEGYR = CLIM
   
       set FILE = vegfile
       set   nz = 1
       /bin/rm CNLAI*
       /bin/rm CNSAI*
   
       while ( $nz <= 3 )
   	set   nv = 1 
   	while ($nv <= 4 )
   	    /bin/ln -s ../VEGDATA/CNLAI${nv}${nz}_${VEGYR}.data CNLAI${nv}${nz}.data
   	    /bin/ln -s ../VEGDATA/CNSAI${nv}${nz}_${VEGYR}.data CNSAI${nv}${nz}.data
   	    echo "CNLAI${nv}${nz}_FILE:                       CNLAI${nv}${nz}.data" >> $FILE
   	    echo "CNSAI${nv}${nz}_FILE:                       CNSAI${nv}${nz}.data" >> $FILE
   	    @ nv++ 
           end
   	@ nz++
       end
       /bin/mv LDAS.rc LDAS.rc.tmp
       cat LDAS.rc.tmp $FILE >> LDAS.rc
       /bin/rm LDAS.rc.tmp $FILE
   endif
   
   # ----------------------------------------------------------------------------
   
   set bYEAR = `cat cap_restart | cut -c1-4`
   set bMON  = `cat cap_restart | cut -c5-6`
   set bDAY  = `cat cap_restart | cut -c7-8`
   set bHour = `cat cap_restart | cut -c10-11`
   set bMin  = `cat cap_restart | cut -c12-13`
   
   if($counter == 1) then
      set logYEAR = $bYEAR
      set logMON  = $bMON
      set logDAY  = $bDAY
      set logHour = $bHour
      set logMin  = $bMin
   endif
   
   set old_mwrtm_file  =  $EXPDIR/output/$EXPDOMAIN/rc_out/Y${bYEAR}/M${bMON}/${EXPID}.ldas_mwRTMparam.${bYEAR}${bMON}${bDAY}_${bHour}${bMin}z.nc4
   set old_catch_param =  $EXPDIR/output/$EXPDOMAIN/rc_out/Y${bYEAR}/M${bMON}/${EXPID}.ldas_catparam.${bYEAR}${bMON}${bDAY}_${bHour}${bMin}z.bin
   if ( -l "$old_mwrtm_file" ) then
      set old_mwrtm_file = `/usr/bin/readlink -f $old_mwrtm_file`
   endif  
   if ( -l "$old_catch_param" ) then
      set old_catch_param = `/usr/bin/readlink -f $old_catch_param`
   endif  

 
   /bin/cp LDAS.rc  $EXPDIR/output/$EXPDOMAIN/rc_out/Y${bYEAR}/M${bMON}/${EXPID}.ldas_LDAS_rc.${bYEAR}${bMON}${bDAY}_${bHour}${bMin}z.txt
   /bin/cp CAP.rc  $EXPDIR/output/$EXPDOMAIN/rc_out/Y${bYEAR}/M${bMON}/${EXPID}.ldas_CAP_rc.${bYEAR}${bMON}${bDAY}_${bHour}${bMin}z.txt
   
   
   echo 'date at starting the model run' >> $HOMDIR/timing.txt
   echo `date` >> $HOMDIR/timing.txt
   # Run GEOSldas.x
   # --------------
   # clean up
   $GEOSBIN/RmShmKeys_sshmpi.csh

   # Debugging
   # ---------
   if ( $debug_flag == 1 ) then
      echo ""
      echo "------------------------------------------------------------------"
      echo ""
      echo "lenkf.j -debug:"
      echo ""
      echo "To start debugging, you must now manually launch your debugging tool"
      echo "with GEOSldas.x from here, e.g.,"
      echo ""           
      echo "   totalview $GEOSBIN/GEOSldas.x"           
      echo ""
      echo "Availability of tools depends on the computing system and may require"
      echo "loading modules.  For more information, check with your computing center."
      echo "See also GEOSldas Wiki at https://github.com/GEOS-ESM/GEOSldas/wiki"
      echo ""
      exit
   endif
   
   @ oserver_nodes = 0
   @ writers = 0

   set total_npes = $SLURM_NTASKS

   if ($oserver_nodes == 0) then
      set oserver_options = ""
   else
      set oserver_options = "--oserver_type multigroup --nodes_output_server $oserver_nodes  --npes_backend_pernode $writers"
   endif

   $RUN_CMD $total_npes $GEOSBIN/GEOSldas.x --npes_model $numprocs $oserver_options 
   
   if( -e EGRESS.ldas ) then
      set rc = 0
      echo GEOSldas Run Status: $rc
   else
      set rc = -1
      echo GEOSldas Run Status: $rc
      echo "ERROR: GEOSldas run FAILED, exit without post-processing"
      exit
   endif
   
   echo 'date at start of post-processing' >> $HOMDIR/timing.txt
   echo `date` >> $HOMDIR/timing.txt
   
   #######################################################################
   #              Move Legacy LDASsa Files to ana/ens_avg Directory
   #######################################################################

   # must be done before moving HISTORY files
   
   set ObsFcses = `ls *.ldas_ObsFcstAna.*.bin` 
   foreach obsfcs ( $ObsFcses ) 
      set ThisTime = `/lustre/catchment/bin_2/echo $obsfcs | rev | cut -d'.' -f2 | rev`
      set TY = `/lustre/catchment/bin_2/echo $ThisTime | cut -c1-4`
      set TM = `/lustre/catchment/bin_2/echo $ThisTime | cut -c5-6` 
      set THISDIR = $EXPDIR/output/$EXPDOMAIN/ana/ens_avg/Y${TY}/M${TM}/
      if (! -e $THISDIR            ) mkdir -p $THISDIR
      mv $obsfcs ${THISDIR}$obsfcs
   end

   set smapL4s = `ls *.ldas_tile_inst_smapL4SMaup.*.bin` 
   foreach smapl4 ( $smapL4s ) 
      set ThisTime = `/lustre/catchment/bin_2/echo $smapl4 | rev | cut -d'.' -f2 | rev`
      set TY = `/lustre/catchment/bin_2/echo $ThisTime | cut -c1-4`
      set TM = `/lustre/catchment/bin_2/echo $ThisTime | cut -c5-6` 
      set THISDIR = $EXPDIR/output/$EXPDOMAIN/ana/ens_avg/Y${TY}/M${TM}/
      if (! -e $THISDIR            ) mkdir -p $THISDIR
      mv $smapl4 ${THISDIR}$smapl4
   end


   #######################################################################
   #              Move HISTORY Files to cat/ens Directory
   #######################################################################
   
   set outfiles = `ls $EXPID.*[bin,nc4]`
   set TILECOORD=`ls ../output/*/rc_out/*ldas_tilecoord.bin`
   
   # Move current files to /cat/ens
   # ------------------------------
   
   foreach ofile ( $outfiles )
      echo 'line 1' >> $HOMDIR/timing.txt
      echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f2 | rev`
      set ThisTime = `/lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f2 | rev`
      echo 'line 2' >> $HOMDIR/timing.txt
      echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo $ThisTime | cut -c1-4`
      set TY = `/lustre/catchment/bin_2/echo $ThisTime | cut -c1-4`
      echo 'line 3' >> $HOMDIR/timing.txt
      echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo $ThisTime | cut -c5-6`
      set TM = `/lustre/catchment/bin_2/echo $ThisTime | cut -c5-6`
      if ($NENS == 1) then
         echo 'line 4' >> $HOMDIR/timing.txt
         echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo $EXPDIR/output/$EXPDOMAIN/cat/ens0000/Y${TY}/M${TM}/`
         set THISDIR = $EXPDIR/output/$EXPDOMAIN/cat/ens0000/Y${TY}/M${TM}/
      else
         set THISDIR = $EXPDIR/output/$EXPDOMAIN/cat/ens_avg/Y${TY}/M${TM}/
      endif
      if (! -e $THISDIR            ) mkdir -p $THISDIR
      echo 'line 5' >> $HOMDIR/timing.txt
      echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f1 | rev`
      set file_ext = `/lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f1 | rev`
   
      if($file_ext == nc4) then
         echo 'line 6' >> $HOMDIR/timing.txt
         echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /bin/mv $ofile $THISDIR/.`
         /bin/mv $ofile $THISDIR/.
      else
         echo 'line 7' >> $HOMDIR/timing.txt
         echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f2- | rev`
         set binfile   = `/lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f2- | rev`
         echo 'line 8' >> $HOMDIR/timing.txt
         echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c /lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f3- | rev`.ctl
         set decr_file = `/lustre/catchment/bin_2/echo $ofile | rev | cut -d'.' -f3- | rev`.ctl
         echo 'line 9' >> $HOMDIR/timing.txt
         echo `/usr/bin/time --output=$HOMDIR/timing.txt -a -p sh -c ($GEOSBIN/tile_bin2nc4.x $binfile $decr_file $TILECOORD ; \
         mv ${binfile}.nc4 $THISDIR/. ; \
         rm ${binfile}.bin) &`
         ($GEOSBIN/tile_bin2nc4.x $binfile $decr_file $TILECOORD ; \
         mv ${binfile}.nc4 $THISDIR/. ; \
         rm ${binfile}.bin) &
      endif
   end
   wait 
   
   #######################################################################
   #              Post-Process model diagnostic output
   #              (1) Concatenate sub-daily files to daily files
   #              (2) Write monthly means  
   #######################################################################
   
   if ($POSTPROC_HIST > 0) then
   
     set PWD = `pwd`
   
     if ($NENS == 1) then
        set OUTDIR = $EXPDIR/output/$EXPDOMAIN/cat/ens0000/
     else
        set OUTDIR = $EXPDIR/output/$EXPDOMAIN/cat/ens_avg/
     endif
   
     set MONTHDIRS = `ls -d $OUTDIR/*/*`
   
     foreach THISMONTH ($MONTHDIRS)
   
       set MM = `/lustre/catchment/bin_2/echo $THISMONTH | rev | cut -d'/' -f1 | cut -c1-2 | rev`
       set YYYY = `/lustre/catchment/bin_2/echo $THISMONTH | rev | cut -d'/' -f2 | cut -c1-4 | rev`
       set NDAYS = `cal $MM $YYYY | awk 'NF {DAYS = $NF}; END {print DAYS}'`
       
       cd $THISMONTH
       
       foreach ThisCol ($collections)
          # if monthly exists, move on to the next collection
          if (-f $EXPID.${ThisCol}.monthly.$YYYY$MM.nc4) continue

          # create daily and remove the sub-daily
          # ------------------------------------------------------------------
          set day=1
          while ($day <= $NDAYS)
             if ( $day < 10  ) set DD=0${day}
             if ( $day >= 10 ) set DD=${day}
             @ day++    
             set time_steps = `ls -1 $EXPID.$ThisCol.${YYYY}${MM}${DD}_* | rev | cut -d'.' -f2 | rev`
             set LEN_SUB = `/lustre/catchment/bin_2/echo $#time_steps`

             # no file or just one file? nothing to concatenate, move on to the next collection
             if ($LEN_SUB <= 1) continue

             # check if day is complete (get HISTORY time step from first two files)
             set hour1   = `/lustre/catchment/bin_2/echo $time_steps[1] | cut -c10-11`
             set min1    = `/lustre/catchment/bin_2/echo $time_steps[1] | cut -c12-13`
             set hour2   = `/lustre/catchment/bin_2/echo $time_steps[2] | cut -c10-11`
             set min2    = `/lustre/catchment/bin_2/echo $time_steps[2] | cut -c12-13`
             @ dt_hist   = ($hour2 - $hour1) * 60 + ($min2 - $min1)
             @ N_per_day = (24 * 60) / $dt_hist		
             # not enough sub-daily files? move on to the next collection
             if($LEN_SUB < $N_per_day) continue

             set tstep2 = \"`/lustre/catchment/bin_2/echo $time_steps | sed 's/\ /\","/g'`\"

# ----------------------------------------------------------------------------
#
# WARNING: The following block MUST begin in column 1!!!  Do NOT indent!!!
   
cat << EOF > timestamp.cdl
netcdf timestamp {
dimensions:
time = UNLIMITED ; // (NT currently)
string_length = 14 ;
variables:
char time_stamp (time, string_length) ;

data:

time_stamp =
DATAVALUES;
}      
EOF
   
             sed -i -e "s/NT/$LEN_SUB/g" timestamp.cdl
             sed -i -e "s/DATAVALUES/$tstep2/g" timestamp.cdl
             ncgen -k4 -o timestamp.nc4 timestamp.cdl
             ncrcat -h $EXPID.$ThisCol.${YYYY}${MM}${DD}_* ${EXPID}.${ThisCol}.$YYYY$MM$DD.nc4
             ncks -4 -h -v time_stamp timestamp.nc4 -A ${EXPID}.${ThisCol}.$YYYY$MM$DD.nc4
             rm timestamp.cdl
             rm timestamp.nc4
             # rudimentary check for desired nc4 file;  if ok, delete sub-daily files
             if ( -f ${EXPID}.${ThisCol}.$YYYY$MM$DD.nc4 ) then
                if ( ! -z ${EXPID}.${ThisCol}.$YYYY$MM$DD.nc4 ) then
                   rm $EXPID.${ThisCol}.${YYYY}${MM}${DD}_*.nc4
                endif
             endif 
          end # concatenate for each day 

          # write monthly mean file and (optionally) remove daily files
          # ------------------------------------------------------------------

          # NOTE: Collections written with daily frequency ("tavg24" and "inst24") have not
          #       been concatenated into daily files.  There are two possibilities  for the
          #       time stamps of files to be averaged:
          #         *.YYYYMMDD.*       daily files from concatenation of sub-daily files
          #         *.YYYYMMDD_HHMM.*  daily (avg or inst) files written directly by HISTORY.rc
   
          set time_steps  = `ls -1 $EXPID.$ThisCol.${YYYY}${MM}??.* | rev | cut -d'.' -f2 | rev`
          set time_steps_ = `ls -1 $EXPID.$ThisCol.${YYYY}${MM}??_* | rev | cut -d'.' -f2 | cut -d'_' -f2 | rev`
          set LEN  = `/lustre/catchment/bin_2/echo $#time_steps`
          set LEN_ = `/lustre/catchment/bin_2/echo $#time_steps_`

          # check if month is complete 
          if ($LEN != 0) then 
            set dayl = `/lustre/catchment/bin_2/echo $time_steps[$LEN] | cut -c1-8`
            set day1 = `/lustre/catchment/bin_2/echo $time_steps[1] | cut -c1-8`
            @ NAVAIL = ($dayl - $day1) + 1
          else if( $LEN_ != 0 ) then
            set dayl = `/lustre/catchment/bin_2/echo $time_steps_[$LEN_] | cut -c1-8`
            set day1 = `/lustre/catchment/bin_2/echo $time_steps_[1] | cut -c1-8`
            @ NAVAIL = ($dayl - $day1) + 1
          else
            @ NAVAIL = 0
          endif
            
          # not enough days for monthly mean? move on to the next collection
          if($NAVAIL != $NDAYS) continue
   
          # create monthly-mean nc4 file
          ncra -h $EXPID.$ThisCol.${YYYY}${MM}*.nc4 ${EXPID}.${ThisCol}.monthly.$YYYY$MM.nc4
          
          if($POSTPROC_HIST == 2) then
             # rudimentary check for desired nc4 file;  if ok, delete daily files
             if ( -f ${EXPID}.${ThisCol}.monthly.$YYYY$MM.nc4 ) then
                if ( ! -z ${EXPID}.${ThisCol}.monthly.$YYYY$MM.nc4 ) then
                   rm $EXPID.${ThisCol}.${YYYY}${MM}*
                endif
             endif
             continue
          endif
   
       end # each collection
     end # each month
     cd $PWD
   endif # POSTPROC_HIST > 0
   
   #######################################################################
   #   Rename Final Checkpoints => Restarts for Next Segment and Archive
   #        Note: cap_restart contains the current NYMD and NHMS
   #######################################################################
   
   set eYEAR = `cat cap_restart | cut -c1-4`
   set eMON  = `cat cap_restart | cut -c5-6`
   set eDAY  = `cat cap_restart | cut -c7-8`
   set eHour = `cat cap_restart | cut -c10-11`
   set eMin  = `cat cap_restart | cut -c12-13`
   
   # Create rc_out/YYYY/MM 
   # ---------------------
   
   set THISDIR = $EXPDIR/output/$EXPDOMAIN/rc_out/Y${eYEAR}/M${eMON}/
   if (! -e $THISDIR  ) mkdir -p $THISDIR
   
   # Move mwrtm and cat_param
   
   set new_mwrtm_file  =  $EXPDIR/output/$EXPDOMAIN/rc_out/Y${eYEAR}/M${eMON}/${EXPID}.ldas_mwRTMparam.${eYEAR}${eMON}${eDAY}_${eHour}${eMin}z.nc4
   set new_catch_param =  $EXPDIR/output/$EXPDOMAIN/rc_out/Y${eYEAR}/M${eMON}/${EXPID}.ldas_catparam.${eYEAR}${eMON}${eDAY}_${eHour}${eMin}z.bin
   
   if (-f $old_mwrtm_file) then
     if ( -l "$new_mwrtm_file" ) then
        rm -f $new_mwrtm_file
     endif
     ln -rs $old_mwrtm_file $new_mwrtm_file
     rm ../input/restart/mwrtm_param_rst
     ln -rs $new_mwrtm_file ../input/restart/mwrtm_param_rst
   endif
   
   if (-f $old_catch_param) then
     if ( -l "$new_catch_param" ) then
        rm -f $new_catch_param
     endif
     ln -rs $old_catch_param $new_catch_param
   endif
   
   # Move Intermediate Checkpoints to RESTARTS directory
   # ---------------------------------------------------
   
   @ inens = 0
   @ enens = $inens + $NENS
   while ($inens < $enens)
       if ($inens <10) then
          set ENSDIR = `/lustre/catchment/bin_2/echo ens000${inens}`
       else if($inens<100) then
          set ENSDIR=`/lustre/catchment/bin_2/echo ens00${inens}`
       else if($inens < 1000) then
          set ENSDIR =`/lustre/catchment/bin_2/echo ens0${inens}`
       else
          set ENSDIR = `/lustre/catchment/bin_2/echo ens${inens}`
       endif
       set ENSID = `/lustre/catchment/bin_2/echo $ENSDIR | cut -c4-7`
       set ENSID = _e${ENSID}
       if ( $NENS == 1) set ENSID =''
       set THISDIR = $EXPDIR/output/$EXPDOMAIN/rs/$ENSDIR/Y${eYEAR}/M${eMON}/
       if (! -e $THISDIR            ) mkdir -p $THISDIR
   
       set rstf = ${MODEL} 
       if (-f ${rstf}${ENSID}_internal_checkpoint ) then
          set tmp_file = $EXPDIR/output/$EXPDOMAIN/rs/$ENSDIR/Y${eYEAR}/M${eMON}/${EXPID}.${rstf}_internal_rst.${eYEAR}${eMON}${eDAY}_${eHour}${eMin}
          mv ${rstf}${ENSID}_internal_checkpoint $tmp_file
          rm -f $EXPDIR/input/restart/${rstf}${ENSID}_internal_rst
          ln -rs  $tmp_file $EXPDIR/input/restart/${rstf}${ENSID}_internal_rst
       endif
   
       set rstf = 'landpert'
       if (-f ${rstf}${ENSID}_internal_checkpoint ) then
          set tmp_file = $EXPDIR/output/$EXPDOMAIN/rs/$ENSDIR/Y${eYEAR}/M${eMON}/${EXPID}.${rstf}_internal_rst.${eYEAR}${eMON}${eDAY}_${eHour}${eMin}
	  # copy generic restart file to final location/name but remove lat/lon variables
	  #  (lat/lon variables are not correct when running in EASE-grid tile space)
          ncks -4 -O -C -x -v lat,lon ${rstf}${ENSID}_internal_checkpoint $tmp_file
          rm -f ${rstf}${ENSID}_internal_checkpoint 
          set old_rst = `/usr/bin/readlink -f $EXPDIR/input/restart/${rstf}${ENSID}_internal_rst`
          rm -f $EXPDIR/input/restart/${rstf}${ENSID}_internal_rst
          ln -rs $tmp_file $EXPDIR/input/restart/${rstf}${ENSID}_internal_rst
          gzip $old_rst &
       endif
   
       set rstf = 'landassim_obspertrseed'
       if (-f ${rstf}${ENSID}_checkpoint ) then
          set tmp_file = $EXPDIR/output/$EXPDOMAIN/rs/$ENSDIR/Y${eYEAR}/M${eMON}/${EXPID}.${rstf}_rst.${eYEAR}${eMON}${eDAY}_${eHour}${eMin}
          mv ${rstf}${ENSID}_checkpoint $tmp_file
          rm -f $EXPDIR/input/restart/${rstf}${ENSID}_rst
          ln -rs $tmp_file $EXPDIR/input/restart/${rstf}${ENSID}_rst
       endif
   # move intermediate check point files to  output/$EXPDOMAIN/rs/$ENSDIR/Yyyyy/Mmm/ directories
   # -------------------------------------------------------------------------------------------
   
       set rstfiles1 = `ls ${MODEL}${ENSID}_internal_checkpoint.*`
       set rstfiles2 = `ls landpert${ENSID}_internal_checkpoint.*`
       set rstfiles3 = `ls landassim_obspertrseed${ENSID}_checkpoint.*`
   
       foreach rfile ( $rstfiles1 ) 
          set ThisTime = `/lustre/catchment/bin_2/echo $rfile | rev | cut -d'.' -f2 | rev`
          set TY = `/lustre/catchment/bin_2/echo $ThisTime | cut -c1-4`
          set TM = `/lustre/catchment/bin_2/echo $ThisTime | cut -c5-6` 
          set THISDIR = $EXPDIR/output/$EXPDOMAIN/rs/$ENSDIR/Y${TY}/M${TM}/
          if (! -e $THISDIR            ) mkdir -p $THISDIR
          mv $rfile ${THISDIR}${EXPID}.${MODEL}_internal_rst.${ThisTime}.nc4
          gzip ${THISDIR}${EXPID}.${MODEL}_internal_rst.${ThisTime}.nc4 &
       end
       
       foreach rfile ( $rstfiles2 ) 
          set ThisTime = `/lustre/catchment/bin_2/echo $rfile | rev | cut -d'.' -f2 | rev`
          set TY = `/lustre/catchment/bin_2/echo $ThisTime | cut -c1-4`
          set TM = `/lustre/catchment/bin_2/echo $ThisTime | cut -c5-6` 
          set THISDIR = $EXPDIR/output/$EXPDOMAIN/rs/$ENSDIR/Y${TY}/M${TM}/
          if (! -e $THISDIR            ) mkdir -p $THISDIR
             (ncks -4 -O -C -x -v lat,lon $rfile ${THISDIR}${EXPID}.landpert_internal_rst.${ThisTime}.nc4;\
               gzip ${THISDIR}${EXPID}.landpert_internal_rst.${ThisTime}.nc4; \
               rm -f $rfile) &
       end
   
       foreach rfile ( $rstfiles3 ) 
          set ThisTime = `/lustre/catchment/bin_2/echo $rfile | rev | cut -d'.' -f2 | rev`
          set TY = `/lustre/catchment/bin_2/echo $ThisTime | cut -c1-4`
          set TM = `/lustre/catchment/bin_2/echo $ThisTime | cut -c5-6` 
          set THISDIR = $EXPDIR/output/$EXPDOMAIN/rs/$ENSDIR/Y${TY}/M${TM}/
          if (! -e $THISDIR            ) mkdir -p $THISDIR
             mv $rfile ${THISDIR}${EXPID}.landassim_obspertrseed_rst.${ThisTime}.nc4
       end
  
       @ inens ++
   end  ## end of while ($inens < $NENS)
   wait 
   #####################
   # update cap_restart
   # ##################
   
   set CO2LINE = `grep -n -m 1 "CO2_YEAR" $HOMDIR/LDAS.rc | cut -d':' -f1`
   
   if ( $CO2LINE >= 1 ) then
   
       # Update reference year for Carbon Tracker CO2
       ##############################################
       
       set CO2_BEFORE = `sed -n "${CO2LINE}p;d" LDAS.rc | cut -d':' -f2`
       set CAP_BEFORE = `head -1 $HOMDIR/cap_restart | cut -c1-4` 
       @ DY = $CAP_BEFORE - $CO2_BEFORE
       @ CO2_AFTER = `head -1 cap_restart | cut -c1-4` - $DY
       set CO2UPDATE = "CO2_YEAR: $CO2_AFTER"
       sed -i "${CO2LINE} s|.*|$CO2UPDATE|" LDAS.rc
       rm -f $HOMDIR//LDAS.rc
       cp -p LDAS.rc $HOMDIR/LDAS.rc
   endif
   
   rm -f $HOMDIR/cap_restart
   cp cap_restart $HOMDIR/cap_restart
   
   #######################################################################
   #              Update Iteration Counter
   #######################################################################

   set enddate = `/lustre/catchment/bin_2/echo  $END_DATE | cut -c1-8`
   set endhour = `/lustre/catchment/bin_2/echo  $END_DATE | cut -c10-11`
   set capdate = `cat cap_restart | cut -c1-8`
   set caphour = `cat cap_restart | cut -c10-11`
   set caphhmmss = `cat cap_restart | cut -c10-15`

   if ( $capdate < $enddate ) then
     @ counter = $counter + 1
   else if ( $capdate == $enddate && $caphour < $endhour ) then
     @ counter = $counter + 1
   else
     @ counter = ${NUM_SGMT} + 1
   endif
   
## End of the while ( $counter <= ${NUM_SGMT} ) loop ##
end

#######################################################################
#                 Set Next Log and Error Files 
#######################################################################

#set logfile = $EXPDIR/output/$EXPDOMAIN/rc_out/Y${logYEAR}/M${logMON}/${EXPID}.ldas_log.${logYEAR}${logMON}${logDAY}_${logHour}${logMin}z.txt
#set errfile = $EXPDIR/output/$EXPDOMAIN/rc_out/Y${logYEAR}/M${logMON}/${EXPID}.ldas_err.${logYEAR}${logMON}${logDAY}_${logHour}${logMin}z.txt
#
#if (-f GEOSldas_log_txt) then
#   /bin/cp GEOSldas_log_txt $logfile
#   /bin/rm -f GEOSldas_log_txt 
#endif
#
#if(-f GEOSldas_err_txt) then
#  /bin/cp GEOSldas_err_txt $errfile
#  /bin/rm -f GEOSldas_err_txt 
#endif

#######################################################################
#                 Re-Submit Job
#######################################################################

if ( $LADAS_COUPLING > 0 ) then
   if ( $rc == 0 ) then
      /lustre/catchment/bin_2/echo 'SUCCEEDED' > $HOMDIR/lenkf_job_completed.txt
   endif
else
   if ( $rc == 0 ) then
      cd   $HOMDIR
      if ($capdate<$enddate) then
         sbatch $HOMDIR/lenkf.j
	 exit 0
  endif
endif

echo 'date when done with post-processing' >> $HOMDIR/timing.txt
echo `date` >> $HOMDIR/timing.txt

# create the file that says that we have finished this ensemble
set file_write="finished_${this_ens}.txt"
# tell this to PSO_iterations
# create the file
touch $EXPDIR/../$file_write

# set everything to zero to be changed later
set runs_done=0
set pso_done=0
set convergence=0

# if this is ensemble zero, you can be allowed to do the calculations
# else continue to check until calcuations are done
if ( $this_ens == 0 ) then
  # wait for the running of all particles to be completed
  while ( $runs_done == 0 ) 
    @ runs_done=`python3 $HOMDIR/check_continue.py 0 $EXPDIR`
  end
  /lustre/catchment/bin_2/echo `python3 $HOMDIR/main.py $EXPDIR` > convergence_message.txt
  @ convergence=`cat convergence_message.txt | rev | cut -c -1`
  # get the total number of particles that we are running
  set total_particles = `awk '/total_particles=/{print $NF}' $HOMDIR/../../start_runs.sh | cut -d'=' -f2`
  # the time that we need to set to restart
  set fulltime="${capdate} ${caphhmmss}"
  # loop over all the particles to manipulate them
  set p = 0
  while ( ${p} < ${total_particles} )
    # remove the finished file
    rm $EXPDIR/../"finished_${p}.txt"
    # update the cap restart for each directory
    sed -i "s/$fulltime/$BEG_DATE/" $EXPDIR/../$p/run/cap_restart
    set startyear = `cat cap_restart | cut -c1-4`
    set startmon = `cat cap_restart | cut -c5-6`
    set startday = `cat cap_restart | cut -c7-8`
    set starthour = `cat cap_restart | cut -c10-11`
    set startmin = `cat cap_restart | cut -c12-13`
    # restart from the original model
    cp $EXPDIR/../$p/output/$EXPDOMAIN/rs/$ENSDIR/Y${startyear}/M${startmon}/${EXPID}.${MODEL}_internal_rst.${startyear}${startmon}${startday}_${starthour}${startmin} $EXPDIR/../$p/input/restart/${MODEL}_internal_rst
    cp $EXPDIR/../$p/output/$EXPDOMAIN/rs/$ENSDIR/Y${startyear}/M${startmon}/${EXPID}.vegdyn_internal_rst $EXPDIR/../$p/input/restart/vegdyn_internal_rst
    @ p++
  end
  echo 'date when done with all' >> $HOMDIR/timing.txt
  echo `date` >> $HOMDIR/timing.txt
  # restart based off of the returned convergence code
  if ($convergence == 0) then
     echo 'CONVERGED, convergence=0' >> $HOMDIR/PSO_iterations.txt
  else if ($convergence == 1) then
     echo 'resubmitted on same job, convergence=1' >> $HOMDIR/PSO_iterations.txt
     sbatch $HOMDIR/../../start_runs.sh
  else if ($convergence == 2) then
     echo 'resubmitted on new job, convergence=2' >> $HOMDIR/PSO_iterations.txt
     sbatch $HOMDIR/../../start_runs.sh
  else if ($convergence == 3) then
     echo 'MAX_ITER REACHED WITHOUT PSO CONVERGENCE, convergence=3' >> $HOMDIR/PSO_iterations.txt
  endif
endif
