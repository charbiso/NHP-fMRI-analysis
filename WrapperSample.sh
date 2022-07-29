#!/usr/bin/env bash
umask u+rw,g+rw # give group read/write permissions to all new files
set -e    # stop immediately on error

#  IMPORTANT: you must have MRCATDIR and MATLABBIN set as global environment variables (in your .bash_profile) for scripts to run
#  MRCATDIR points to your local MrCat-dev directory
#  MATLABBIN points to your local Matlab app directory's bin folder (where matlab app is located)

studyDir="/Users/carolineharbison/Desktop/Kentaro_data"
monkey="Zap"
session="2"
sessionDir=$studyDir/$monkey/$session

echo ""
echo "preprocessing of awake behaving macaque EPI timeseries"

# ---------------- #
# PREPARE RAW DATA
# ---------------- #

# NOTE: for BATCH preprocessing, this is better run with a separate script (as it may require user input)!
# NOTE: use argument --isrestingstate=1 (defaults to 0) to set up session folders only for resting state data (or only non-resting state data)

# sh $MRCATDIR/pipelines/PreprocFunc_macaque/PrepareRawData.sh --sessdir=$sessionDir --isrestingstate=1
#sh $MRCATDIR/pipelines/PreprocFunc_macaque/PrepareRawData.sh --sessdir=$sessionDir

# -------------- #
# RECONSTRUCTION
# -------------- #

# run the reconstruction, start a timer
#SECONDS=0
#echo "starting reconstruction"

#sh $MRCATDIR/pipelines/PreprocFunc_macaque/Reconstruction_macaque.sh --sessdir=$sessionDir

#echo "  seconds elapsed: $SECONDS"
#echo ""

# finds the full path to the ep2d dir which should now have the reconstructed EPI (f.nii.gz)
epiDir=$(find $sessionDir -maxdepth 1 -d -name "ep2d*")
echo $epiDir
# ----------------------------------- #
# MOTION CORRECTION / SLIGN ALIGNMENT
# ----------------------------------- #

# run the motion correction, start a timer
SECONDS=0
echo "starting motion correction"

# here be magic
sh /Users/carolineharbison/Desktop/Kentaro_data/Scripts/MotionCorrection_macaque_3000vol.sh --episeries=$epiDir/f --t1wimg=$studyDir/$monkey/struct/struct_restore  --t1wmask=$studyDir/$monkey/struct/struct_brain_mask

echo "  seconds elapsed: $SECONDS"
echo ""

# --------------------------- #
# FUNC TO STRUCT REGISTRATION
# --------------------------- #

# run the EPI to T1w registration, start a timer
SECONDS=0
echo "starting EPI to T1w registration"

# here be more magic
sh $MRCATDIR/pipelines/PreprocFunc_macaque/RegisterFuncStruct_macaque.sh --epiimg=$epiDir/f_mean --t1wimg=$studyDir/$monkey/struct/struct_restore --t1wmask=$studyDir/$monkey/struct/struct_brain_mask

echo "  seconds elapsed: $SECONDS"
echo ""


