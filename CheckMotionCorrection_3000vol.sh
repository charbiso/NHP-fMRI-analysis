#!/usr/bin/env bash
umask u+rw,g+rw # give group read/write permissions to all new files
set -e    # stop immediately on error

<< COMMENT

This script can be used both with the new MotionCorrection_macaque_3000vol.sh and the original MotionCorrection script. 
It has new lines added that ensure that it keeps checking the motion correction after vol 3000.

C Harbison 07/22

COMMENT

# ----- #
# USAGE
# ----- #

usage() {
cat <<EOF

Checking the quality of the EPI motion correction (slice alignment). This code
accompanies MotionCorrection_macaque.sh, please see there for more info.

usage:
  CheckMotionCorrection.sh --episeries=<4D EPI timeseries>

example:
  CheckMotionCorrection.sh --episeries=./project/monkey/sess/functional/func

arguments:
  Please see MotionCorrection_macaque.sh for more (background) information.

  obligatory:

    --episeries=<4D EPI timeseries>
        The whole uncorrected EPI timeseries (4D). From this series the
        reference will be extracted, processed, and subsequently all volumes
        will be aligned slice-by-slice to correct for linear and non-linear
        distortions in the phase-encoding direction.


  optional:

    --refbrainmask=<3D reference brain mask> (default: <epi>_ref_brain_mask)
        A brain mask is used to restrict the quality assessment to brain voxels
        only. This brain mask will likely have been created or obtained by
        MotionCorrection_macaque.sh, but could be anything. By default the brain
        mask is assumed to be [episeries][suffixref][suffixbrainmask]. Please
        see below for the defaults of those suffices.

    --workdir=<dir> (default: /[path]/[to]/[epiDir]/work)
        The directory where all intermediate images and results will be
        stored. These will mainly be individual volumes and slices. When this
        folder is newly created (and not inherited from
        MotionCorrection_macaque.sh) it will be deleted after completion, except
        when running in debug-mode.

    --suffixref=<string> (default: "_ref")
        A substring that is appended to identify the reference image.

    --suffixaligned=<string> (default: "_aligned")
        A substring that is appended to identify the aligned timeseries.

    --suffixbrainmask=<string> (default: "_brain_mask")
        A substring that is appended to identify the brain mask.

    --suffixdetrend=<string> (default: "_detrend")
        A substring that is appended to identify detrended 4D images.

    --reportfile=<file name> (default: empty)
        When this argument is provided it will write all terminal outputs also
        to the specified report file. This is the default for
        MotionCorrection_macaque.sh

    --debug=<0 or 1> (default: 0)
        Keep all intermediate images and provide verbose output.

    --help
        Print this help menu.

EOF
}

# -------- #
# OVERHEAD
# -------- #

# if no arguments are given, or help is requested, return the usage
[[ $# -eq 0 ]] || [[ $@ =~ --help ]] && usage && exit 0

# if too few arguments given, return the usage, exit with error
[[ $# -lt 1 ]] && echo "" && >&2 printf "\nError: not enough input arguments.\n\n" && usage && exit 1


# ------------------------- #
# ARGUMENTS AND DEFINITIONS
# ------------------------- #

# parse the input arguments
for a in "$@" ; do
  case $a in
    --episeries=*)      epi="${a#*=}"; shift ;;
    --refbrainmask=*)   refBrainMask="${a#*=}"; shift ;;
    --workdir=*)        workDir="${a#*=}"; shift ;;
    --suffixref=*)      sRef="${a#*=}"; shift ;;
    --suffixaligned=*)  sAligned="${a#*=}"; shift ;;
    --suffixbrainmask=*) sBrainMask="${a#*=}"; shift ;;
    --suffixdetrend=*)  sDetrend="${a#*=}"; shift ;;
    --reportfile=*)     reportFileProgress="${a#*=}"; shift ;;
    --debug=*)          flgDebug="${a#*=}"; shift ;;
    --debug)            flgDebug=1; shift ;; # compatibility option
    *)                  shift ;; # unspecified argument
  esac
done

# test for obligatory arguments
[[ -z $epi ]] && >&2 printf "\nError: Please provide an EPI timeseries input.\n\n" && exit 1

# infer debug and report settings
[[ -z $flgDebug ]] && flgDebug=0
[[ -z $reportFileProgress ]] && reportFileProgress=/dev/null

# infer the suffixes
[[ -z $sRef ]] && sRef="_ref"
[[ -z $sAligned ]] && sAligned="_aligned"
[[ -z $sBrainMask ]] && sBrainMask="_brain_mask"
[[ -z $sBiasCorr ]] && sBiasCorr="_restore"
[[ -z $sDetrend ]] && sDetrend="_detrend"
sMean="_mean"

# infer EPI directory, and retrieve the absolute path
epiDir=$(cd "$(dirname $epi)" && pwd)

# remove path and extension from input image
epi=$(basename $epi)
epi=$(remove_ext $epi)

# force images to be stored in NIFTI_GZ format
FSLOUTPUTTYPE_ORIG=$FSLOUTPUTTYPE
export FSLOUTPUTTYPE=NIFTI_GZ

# set reference image and brain mask
[[ -z $refBrainMask ]] && refBrainMask=$epiDir/${epi}${sRef}${sBrainMask}

# test if images exist and are in the NIFTI_GZ format
for testImg in $epiDir/$epi $refBrainMask ; do
  [[ $(imtest $testImg) -eq 0 ]] && >&2 printf "\nError: The input image\n  %s\ndoes not exist or is not in a supported format.\n\n" "$testImg" && exit 1
  [[ $(echo $testImg.* | sed "s#$testImg##g") != ".nii.gz" ]] && >&2 printf "\nError: All input images must be in NIFTI_GZ image format (*.nii.gz).\n\n" && exit 1
done

# infer the directory holding the intermediate files
[[ -z $workDir ]] && workDir=$epiDir/work
[[ -d $workDir ]] && flgNewWorkDir=0 || flgNewWorkDir=1

# ensure the directory exists and use absolute path
mkdir -p $workDir
workDir=$(cd $workDir && pwd)

# create a directory to store the report(s)
mkdir -p $epiDir/report


# ---- #
# WORK
# ---- #
echo "" | tee -a $reportFileProgress
echo "CHECKING QUALITY OF MOTION CORRECTION" | tee -a $reportFileProgress

# determine whether the intermediate aligned volumes are still present or not
for f in $workDir/vol*_aligned.nii.gz ; do [[ -e "$f" ]] && flgRedoSplit=0 || flgRedoSplit=1; break; done
if [[ $flgRedoSplit -eq 1 ]] ; then
  # split the EPI 4D timeseries in volumes
  echo "  splitting the 4D timeseries in 3D volumes" | tee -a $reportFileProgress
  nVol=$(fslval $epiDir/${epi}${sAligned} dim4)
  fslsplit $epiDir/${epi}${sAligned} $workDir/${epi}${sAligned}_vol
  volList1="$(find $workDir/${epi}${sAligned}_vol0[0-9][0-9][0-9].nii.gz -type f)"
  if ((nVol > 999)); then
    volList2="$(find $workDir/${epi}${sAligned}_vol1[0-9][0-9][0-9].nii.gz -type f)"
    if ((nVol > 1999)); then
      volList3="$(find $workDir/${epi}${sAligned}_vol2[0-9][0-9][0-9].nii.gz -type f)"
      if ((nVol > 2999)); then
        volList4="$(find $workDir/${epi}${sAligned}_vol3[0-9][0-9][0-9].nii.gz -type f)"
      fi
    fi
  fi
else
  # use the intermediate aligned volumes
  [[ -z $nVol ]] && nVol=$(fslval $epiDir/${epi}${sAligned} dim4)
  echo nVol
  volList1="$(find $workDir/vol0[0-9][0-9][0-9]${sAligned}.nii.gz -type f)"
  if ((nVol > 999)); then
    volList2="$(find $workDir/vol1[0-9][0-9][0-9]${sAligned}.nii.gz -type f)"
    if ((nVol > 1999)); then
      volList3="$(find $workDir/vol2[0-9][0-9][0-9]${sAligned}.nii.gz -type f)"
      if ((nVol > 2999)); then
        volList4="$(find $workDir/vol3[0-9][0-9][0-9]${sAligned}.nii.gz -type f)"
      fi
    fi
  fi
fi

# determine to detrend or not
[[ $nVol -gt 3 ]] && flgDetrend=1 || flgDetrend=0

# select good volumes and create an average in two stages
for stage in 1 2 ; do

  # stage 1 or 2
  if [[ $stage -eq 1 ]] ; then
    # calculate how much slices look like their neighbours for each volume
    echo "  selecting volumes with high-consistency across slices" | tee -a $reportFileProgress
    sStage="Slices"
    fact=3
  else
    if [[ $flgDetrend -eq 1 ]] ; then
      echo "  detrending the timeseries" | tee -a $reportFileProgress
      $MRCATDIR/core/detrend $epiDir/${epi}${sAligned} $epiDir/${epi}${sAligned}${sDetrend} -m
      echo "  splitting the detrended timeseries" | tee -a $reportFileProgress
      fslsplit $epiDir/${epi}${sAligned}${sDetrend} $workDir/${epi}${sAligned}${sDetrend}_vol -t
      echo "  selecting volumes that are well-aligned to the mean" | tee -a $reportFileProgress
      volList1="$(find $workDir/${epi}${sAligned}${sDetrend}_vol0[0-9][0-9][0-9].nii.gz -type f)"
      if ((nVol > 999)); then
        volList2="$(find $workDir/${epi}${sAligned}${sDetrend}_vol1[0-9][0-9][0-9].nii.gz -type f)"
        if ((nVol > 1999)); then
          volList3="$(find $workDir/${epi}${sAligned}${sDetrend}_vol2[0-9][0-9][0-9].nii.gz -type f)"
          if ((nVol > 2999)); then
            volList4="$(find $workDir/${epi}${sAligned}${sDetrend}_vol3[0-9][0-9][0-9].nii.gz -type f)"
          fi
        fi
      fi
    else
      printf "  only %d volumes, timeseries won't be detrended\n" $nVol | tee -a $reportFileProgress
      echo "  selecting volumes that are well-aligned to the mean" | tee -a $reportFileProgress
    fi
    sStagePrev=$sStage
    sStage="Overall"
    refImgTmp=$epiDir/report/${epi}${sAligned}_good${sStagePrev}${sMean}
    fact=3
  fi

  # calculate the image similarity metric
  reportFile=$epiDir/report/rvalue${sStage}.txt
  > $reportFile
  for vol in $volList1; do
    # stage 1: perform mean filtering across slices
    if [[ $stage -eq 1 ]] ; then
      refImgTmp=${vol%.nii.gz}_sliceInterp
      fslmaths $vol -kernel boxv3 1 1 3 -fmean $refImgTmp
    fi
    # compare volume using NormalizedCorrelation (alternative: Mattes mutual-information)
    ImageMath 3 ${vol%.nii.gz}out.nii.gz NormalizedCorrelation ${vol} $refImgTmp.nii.gz $refBrainMask.nii.gz >> $reportFile # Mattes: {Optional-number-bins=32} {Optional-image-mask}
  done
  if ((nVol > 999)); then
    for vol in $volList2; do
      # stage 1: perform mean filtering across slices
      if [[ $stage -eq 1 ]] ; then
        refImgTmp=${vol%.nii.gz}_sliceInterp
        fslmaths $vol -kernel boxv3 1 1 3 -fmean $refImgTmp
      fi
      # compare volume using NormalizedCorrelation (alternative: Mattes mutual-information)
      ImageMath 3 ${vol%.nii.gz}out.nii.gz NormalizedCorrelation ${vol} $refImgTmp.nii.gz $refBrainMask.nii.gz >> $reportFile # Mattes: {Optional-number-bins=32} {Optional-image-mask}
    done
  fi
  if ((nVol > 1999)); then
    for vol in $volList3; do
      # stage 1: perform mean filtering across slices
      if [[ $stage -eq 1 ]] ; then
        refImgTmp=${vol%.nii.gz}_sliceInterp
        fslmaths $vol -kernel boxv3 1 1 3 -fmean $refImgTmp
      fi
      # compare volume using NormalizedCorrelation (alternative: Mattes mutual-information)
      ImageMath 3 ${vol%.nii.gz}out.nii.gz NormalizedCorrelation ${vol} $refImgTmp.nii.gz $refBrainMask.nii.gz >> $reportFile # Mattes: {Optional-number-bins=32} {Optional-image-mask}
    done
  fi

  # find best match (lowest normalized correlation r-value)
  min=$(awk 'NR==1{min=$0+0} $1<min{min=$0} END {print min}' $reportFile)

  # calculate standard deviation
  sd=$(awk '{ sum += $0; sumsq += $0^2 } END { print sqrt( ( sumsq - (sum^2 / NR) ) / (NR-1) ) }' $reportFile)

  # define threshold at 3 times the standard deviation above the lowest r-value
  thr=$(echo $min $sd $fact | awk '{ print $1 + ($3*$2) }')

  # select good volumes with correlation below the threshold
  if [[ $flgRedoSplit -eq 1 ]] ; then
    avgList1=$(nl $reportFile | awk -v thr=$thr '($2<thr && $1<1501) { printf "'$workDir'/'${epi}${sAligned}'_vol%04d\n", $1-1 }')
    if ((nVol > 1500)); then
      avgList2=$(nl $reportFile | awk -v thr=$thr '($2<thr && $1>1500) { printf "'$workDir'/'${epi}${sAligned}'_vol%04d\n", $1-1 }')
    fi
  else
    avgList1=$(nl $reportFile | awk -v thr=$thr '($2<thr && $1<1501) { printf "'$workDir'/vol%04d'${sAligned}'\n", $1-1 }')
    if ((nVol > 1500)); then
      avgList2=$(nl $reportFile | awk -v thr=$thr '($2<thr && $1>1500) { printf "'$workDir'/vol%04d'${sAligned}'\n", $1-1 }')
    fi
  fi

  # save a report of the good and the bad volume indices
  echo "good volumes, zero indexed (FSL style)" > $epiDir/report/good${sStage}.txt
  nl $reportFile | awk -v thr=$thr '$2<thr{ print $1-1}' >> $epiDir/report/good${sStage}.txt
  echo "bad volumes, zero indexed (FSL style)" > $epiDir/report/bad${sStage}.txt
  nl $reportFile | awk -v thr=$thr '$2>=thr{ print $1-1}' >> $epiDir/report/bad${sStage}.txt
  if ((nVol > 1500)); then
    nGood_a=$(echo "$avgList1" | wc -l)
    nGood_b=$(echo "$avgList2" | wc -l)
    ((nGood=nGood_a + nGood_b))
  else
    nGood=$(echo "$avgList1" | wc -l)
  fi

  [[ $stage -eq 1 ]] && nBadStage1=$((nVol-nGood))
  [[ $stage -eq 2 ]] && nBadStage2=$((nVol-nGood))

  # average the good volumes
  [[ $stage -eq 1 ]] && echo "  average EPI images with low slice-by-slice variability" | tee -a $reportFileProgress
  [[ $stage -eq 2 ]] && echo "  average EPI images that are well-aligned to the mean" | tee -a $reportFileProgress
  
  if ((nVol > 1500)); then
    fslmerge -t $epiDir/report/${epi}${sAligned}_good${sStage}${sMean}_x1 $avgList1
    fslmerge -t $epiDir/report/${epi}${sAligned}_good${sStage}${sMean}_x2 $avgList2
    fslmerge -t $epiDir/report/${epi}${sAligned}_good${sStage}${sMean} $epiDir/report/${epi}${sAligned}_good${sStage}${sMean}_x*.nii.gz
  else
    fslmerge -t $epiDir/report/${epi}${sAligned}_good${sStage}${sMean} $avgList1
  fi
  fslmaths $epiDir/report/${epi}${sAligned}_good${sStage}${sMean} -Tmean $epiDir/report/${epi}${sAligned}_good${sStage}${sMean}
done

# copy and rename the good mean EPI image
imcp $epiDir/report/${epi}${sAligned}_good${sStage}${sMean} $epiDir/${epi}${sMean}

# report number of good and bad volumes
printf "  report\n" | tee -a $reportFileProgress
printf "    total number of volumes: %d\n" $nVol | tee -a $reportFileProgress
printf "    with bad slice-alignment: %d\n" $nBadStage1 | tee -a $reportFileProgress
printf "    poorly matching the mean: %d\n" $nBadStage2 | tee -a $reportFileProgress



# -------- #
# CLEAN-UP
# -------- #

# remove temporary files and images when not in debug mode
if [[ $flgDebug -ne 1 ]] && [[ $flgNewWorkDir -eq 1 ]] ; then
  rm -rf $workDir
  [[ $flgDetrend -eq 1 ]] && imrm $epiDir/${epi}${sAligned}${sDetrend}
fi

# reset default file type
FSLOUTPUTTYPE=$FSLOUTPUTTYPE_ORIG
export FSLOUTPUTTYPE
