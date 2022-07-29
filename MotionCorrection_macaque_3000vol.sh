#!/usr/bin/env bash
umask u+rw,g+rw # give group read/write permissions to all new files
set -e    # stop immediately on error

# TODO: idea: try to align the volume first in one go, with all slices together.
# This might give better results for volumes without much distortion and could
# serve as a perfect initialisation for the slice-by-slice alignment or might
# actually outperform it.

# TODO: should we cap the resampled (aligned) EPIs at zero? Just like the
# resampled structural in RegisterFuncStruct_macaque? Probably.

<<COMMENT

I have edited the original MotionCorrection_macaque.sh script so that it can pre-process images that have more than 3000 volumes. 
I have also updated the CheckMotionCorrection script so that it also works with such large files.

C Harbison - 07/22

COMMENT

# ------------- #
# HELP AND INFO
# ------------- #

usage() {
cat <<EOF

Motion correction for macaque EPI timeseries. High-quality volumes are selected
from the timeseries and averaged to serve as a reference. Then all volumes are
registered slice-by-slice to the reference - first linearly, then non-linearly -
to correct for distortions in the phase-encoding direction induced by motion.
This is a computationally intensive process and because it has to be run
slice-by-slice and volume-by-volume it's implementation is not particularly
efficient. At standard (high) quality it will take about 50 seconds per volume
on a standard CPU, while running at 'okay' quality will still take about 35
seconds per volume.

usage:
  MotionCorrection_macaque.sh --episeries=<4D EPI timeseries>

example:
  MotionCorrection_macaque.sh --episeries=./project/monkey/sess/functional/func

arguments:
  Please note that all images should be in NIFTI_GZ image format (*.nii.gz).
  There is no need to include this fixed extension in any of the arguments.

  obligatory:

    --episeries=<4D EPI timeseries>
        The whole uncorrected EPI timeseries (4D). From this series the
        reference will be extracted, processed, and subsequently all volumes
        will be aligned slice-by-slice to correct for linear and non-linear
        distortions in the phase-encoding direction.


  optional:

    --quality=<int> (default: 2)
        Set the quality of the registration, from 0 (okay quality), to 1 (good
        quality), to 2 (high quality), to 3 (potentially best quality, but risk
        of over-fitting). Please note that whatever quality you pick, it will
        always be slow. The higher the quality setting, the slower it will be.
        As a rough guide, best quality is twice as slow as okay quality. Please
        see the general comments above.

    --refimg=<3D reference image> (default: empty)
        By default, the reference image and masks are newly created from the EPI
        timeseries. You can choose to provide a reference image and use that
        instead. This is helpful to reproduce exactly the same session, to align
        across session, or to slightly speed-up the code when the reference is
        already available.

    --refbrainmask=<3D reference brain mask> (default: empty)
        By default, the reference brain mask is newly created based on the
        reference image (and ideally the T1w structural image). You can choose
        to provide a binary reference brain mask and use that instead. There is
        a slight random component in creating a brain mask, so providing an
        existing mask is helpful to reproduce exactly the same results.

    --refheadmask=<3D reference head mask> (default: empty)
        By default, the reference head mask is newly created from the reference
        image and brain mask. You can choose to provide a binary reference head
        mask and use that instead. There is no random component in creating a
        head mask, so providing an existing mask is helpful to speed-up the code
        or when the algorithm here does not suffice.

    --workdir=<dir> (default: /[path]/[to]/[epiDir]/work)
        The directory where all intermediate images and results will be
        stored. These will mainly be individual volumes and slices. This
        folder will be deleted after completion, except when it already
        existed at the start or when running in debug-mode.

    --betmethod=<"T1W", "EPI"> (default: "T1W")
        If the reference image is created from the EPI timeseries (default) then
        the brain mask will be created using either a matching T1w image and
        mask (best results, using RegisterFuncStruct_macaque.sh), or using the
        EPI image alone (using bet_macaque.sh). If '--betmethod=T1W' it is
        required to also provide a T1w image and T1w brain mask using '--t1wimg'
        and '--t1wmask'.

    --t1wimg=<T1w image>
        A T1w image serving as a target for the EPI reference brain extraction.
        Required for '--betmethod=T1W'.

    --t1wmask=<binary brain mask>
        A binary brain mask corresponding to the T1w image servig as a template
        for the EPI reference brain mask. Required for '--betmethod=T1W'.

    --checkreg=<0 or 1> (default: 1)
        By default, and on strong recommendation, the quality of the
        registration is checked and improved if needed. First, if the original
        un-moved slice is found to already be a great match with the reference
        (determined by '--checkregthresh'), the registration is skipped and the
        original slice is maintained. Second, if the quality of the linear
        registration is found to be poor this step is repeated with a new
        initialisation. It will also report on the final linear registration
        similarity metric (r-value). This check detects the odd case where the
        registration gets stuck in a local minimum. However, for some animals
        such failures can in fact be quite frequent. Third, it checks whether
        after the linear registration the match to the reference is perhaps
        already good enough (analogous to the first check). Only when room for
        improvement is expected will non-linear registration be performed.
        Fourth, the quality of the non-linear registration and only implements
        this if it is in fact an improvement over the linear registration. For
        volumes with minimal distortions, the linear registration might be the
        best solution. These check are done for all slices of all volumes, and
        that adds up to about 50% longer computing time. However, Please set
        this flag to 0 to skip this check and save time at the (relatively high)
        cost of more errors and lower registration accuracy.

    --checkregthresh=<float> (default: dependent on --quality)
        When '--checkreg' is set to 1, the similarity of the original unmoved
        slice is compared to the reference. If the similarity is better than the
        target, further registration is skipped. This check is repeated before
        the start of the non-linear registration. Please see '--checkreg' for
        more details. The value of '--checkregthresh' must be a floating-point
        value between -1 and 0, corresponding to a normalized correlation value
        (r-value). The default value is dependent on '--quality'
        quality=0: -0.95
        quality=1: -0.97
        quality>1: -0.98

    --storelinear=<0 or 1> (default: 1)
        Set this flag to store the affine transformations. These could be
        helpful to regress out motion artefacts during analysis (GLM) or to
        check for the severity of the distortions. For the last purpose the
        y-scaling might be particularly helpful and easy to implement.

    --storewarp=<0 or 1> (default: 1)
        Set this flag to store the non-linear warp transformations. These could
        be helpfult to correct for motion distortions on a voxel-by-voxel basis.
        This is not a trivial operation. As an alternative the first 12
        principal components of the displacement field over time are provided.
        These could be included in a GLM as co-variates of no interest. Please
        note that storing all the warp files will take up a lot of storage
        space, so unset this flag if you don't plan to use it.

    --maskzeros=<0 or 1> (default: 1)
        By default, voxels with zero value, i.e. voxels far away from the
        brain/head, are ignored in the cost-function. You can set to include
        them. This will bias the transformation to a flat deformation beyond
        the brain/head.

    --restricthead=<0, 1, or 2> (default: 1)
        By default (1), the registration won't consider the sides of the head
        (anything more than 20% lateral to the brain). This prevents the
        registration optimising the head, rather than the brain. You can
        consider to further restrict the head by setting this argument to (2).
        Then it will set a relative width for each slice separately (120% of the
        brain width in that slice, with a minimum of 31 voxels). This probably
        harms the registration for the superior and inferior slices, but will be
        slightly faster to compute. Lastly, you can ignore the restriction and
        include the whole head (0). That's always a safe bet if weird stuff
        happens.

    --suffixref=<string> (default: "_ref")
        A substring that is appended to identify the reference image.

    --suffixaligned=<string> (default: "_aligned")
        A substring that is appended to identify the aligned timeseries.

    --suffixbrainmask=<string> (default: "_brain_mask")
        A substring that is appended to identify the brain mask.

    --suffixheadmask=<string> (default: "_head_mask")
        A substring that is appended to identify the head mask.

    --suffixbiascorr=<string> (default: "_restore")
        A substring that is appended to identify bias-corrected images.

    --suffixdetrend=<string> (default: "_detrend")
        A substring that is appended to identify detrended 4D images.

    --debug=<0 or 1> (default: 0)
        Keep all intermediate images and provide verbose output.

    --verbose=<0 or 1> (default: 0)
        Provide verbose output.

    --info
        Print the background information.

    --help
        Print this help menu.

EOF
}


info() {
cat <<EOF

# ------ #
# ISSUES
# ------ #

# ISSUE: strongly time-varying B0 distortions
The monkeys are head-fixed but can - and do - move their bodies and limbs
considerably. This creates distortions of the main (B0) magnetic field that
result in image distortions in the phase-encoding direction. These distortions
can be extreme, both in the spatial and temporal domain. Because of their
temporal instability, the registration needs to be estimated slice-by-slice. You
can choose to use the registration of a previous slice to initiate the current
linear transformation. This leads to a slight speed-up. However, initializing
the non-linear transformation has detrimental effects on registration quality
and is therefore not supported.

# IDEAS
Our images are acquired in an ascending order, leading to potential saw-tooth
artefacts where odd slices have different distortions than even slices. There is
some potential in the idea to use slices neighbouring in time to improve the
current slice registration. I have tried proper regularization over slices, and
initializing the transform of the current slice based on the previous slice, but
both hav not proven successful, mostly because the distortions vary too much
from slice to slice.


# ISSUE: regularized registration
The registration should only correct for distortions in the phase-encoding
direction, but the distortions can be of such magnitude - especially in the
fringes of the image - and the signal can suffer from such significant drop-out
- especially in the back of the brain - that a strict regularization of the
registration is critical. The current approach is as follows:
  1. Using a liberal mask the source slices are linearly aligned (translation
     followed by scaling along the phase-encoding direction). Because the two
     images to register are of the same modality and from the same acquisition
     session, the cost-function for this linear registration can be set to the
     computationally efficient root-mean-square error.
  2. Using a stricter mask that excludes the posterior neck and skull the source
     slices are non-linearly aligned with a B-Spline regularized symmetric
     diffeomorphic transformation. For this registration the recommended
     cost-function is the local cross-correlation. This allows great sensitivity
     for extreme spatial distortions, even in the presence of signal drop-out. A
     mutual information cost-function would be faster, but might underweight
     strong distortions because it considers the whole slice in one cost
     calculation. The transformation is regularized by a set of b-splines with 5
     knot points along the phase-encoding dimension. Importantly, this set of
     splines does not vary along the orthogonal lateral dimension preventing
     over-fitting. Lastly, this regularization is only applied on each 'update'
     cycle, rather than on the final diffeomorphic transformation. This allows a
     more 'fluid', rather than 'elastic' transformation and benefits the quality
     of the registration.

# IDEAS
The linear registration in step 1 is undoubtedly insufficient for proper
distortion correction. The final result would probably benefit from including
one additional intermediate step (between steps 1 and 2) that would utilize a
somewhat less strict mask, preventing cut-off of extreme distortions. Perhaps
this intermediate registration could even be performed with high-order (less
strict) B-Splines, followed by the more strictly regularized final registration.


# ISSUE: motion parameters
It is generally recommended to include motion parameters in your GLM. If you set
the flag --storelinear=1 your linear motion parameters (scaling and translation
along the y-dimensions) will be stored for each slice in each volume. To store
the non-linear deformation field(s) set the flag --storewarp=1.

# IDEAS
It is recommended to consider at least the linear motion paramters in your GLM.
To do so, you could calculate the average or first eigen variate over slices to
obtain a single scaling and a single translation parameter for each volume. The
GLM would probably benefit if you include not only these two regressors
(co-variates of no interest), but also their first-, or perhaps even
second-order taylor/volterra expansion (exponent and derivative). Please note
that the non-linear deformation fields are not easily translated into a motion
parameters, rather the describe the distortions in three dimensions for each
voxel individually. This could be used for some fancy massively univariate
voxel-by-voxel motion correction, but could also be combined by something
idiotic as averaging or a more fancy I/PCA dimensionality reduction.


# ISSUE: quality control
Please note that the current registration approach, running on 2D slices, is
more susceptible to getting stuck in a local minimum far from the global optibum
than conventioanl 3D volume registration. In the rare case when the registration
fails it likely happens at the very first step: the initialisation of the rigid
registration. When the source and reference images are not overlapping
antsRegistration will give a warning. This is recognized by the code and the
registration is re-run with a different initialisation. However, currently
registrations that end up in a local minimum far from the global optimum are not
detected.

# IDEAS
I have implemetned an option to calculate the registration similarity metric
(r-value), and compare against a desired threshold to decide if the registration
should be re-run with a different initialisation. However, this constitutes a
non-trivial time penalty to benefit the rare cases where it is important. A
better solution would be to let antsRegistration print out the registration cost
itself, but I haven't found a way to make it so.


# ISSUE: brain mask
The choice and quality of the registration mask has a considerable impact on the
quality of the registration. The current approach is as follows:
  1. Use the brain mask of the reference image as a starting point.
  2. Define a head mask based on the intensity of the brain voxels.
  3. Exclude the neck and posterior ghosting based on the brain mask. For the
     top half of the brain, reject anything more than three voxels behind the
     brain. For the bottom half of the brain, reject anything behind the brain
     with a more anterior cut-off the lower the slice.
  4. Optional: leave out the far sides of the skull to focus more on the brain.
  5. Dilate this head mask anteriorly to include the eyes and fill holes. The
     resulting mask will include the brain, side, and front of the head, but
     exclude the neck and inferior posterior skull. This will be the main
     registration mask.
  6. For superior and inferior slices with little or no brain, dilate the mask
     from a slice with enough brain to ensure there are enough voxels to drive
     the registration.
  7. Dilate this mask posteriorly to account for potential distortions in the
     phase-encoding direction in the EPI images to register.


# IDEAS
The registration of superior slices with strong signal drop-out might benefit
from a stricter brain mask that excludes very dark voxels from the posteriorly
dilated head mask.


# ISSUE: reference image
The choice of reference image will impact the quality of the registration.
Currently, the expectation is that there are enough high-quality EPI volumes
without any distortions in the time-series. First, from the whole time-series I
select the top 40% of volumes with the least variability across slices. This is
quantified for each volume by comparing each slice with the average of its
neighbouring slices (using the root-mean-square error as a similarity metric).
These top 40% volumes are averaged to create a temporary reference against which
each of the top 40% volumes is compared. Only the best half of those, the top
20% of the original, are averaged to create the final reference image.

# IDEAS
Ideally, one would repeat the whole distortion correction procedure and use the
mean EPI volume as a reference on the second round. This does of course lead to
a double of the computation time. Also, a mean image of many volumes is
unavoidably more blurry (especially around the posterior edges) and might
therefore not provide a good target reference for the registration.


# ISSUE: bias-correction
Generally, correcting for RF field inhomogeneities is recommended procedure to
improve registration. In this particular case, the rationale is not so clear.
First of all, the source and reference image are the same modality and from the
same session, therefore suffering from the same field inhomogeneities. Second,
given that the signal drop-out is slice specific, the bias-correction would have
to be performed on a slice-by-slice basis. This can potentially lead to
differences in registration from slice to slice. Third, bias-correction could
potentially amplify the noise in otherwise low-signal regions, leading to
mis-registration where the distortion leads to drop-out. It is probably
sufficient, or perhaps even advantageous to deal with differences in signal
strength by adopting a local cross-correlation cost-function in the non-linear
registration stage. Lastly, bias-correction takes time, so is best avoided if
you can.


# ISSUE: reproducability
Running motioncorrection_macaque multiple times will give slightly different
results. This is in fact not due to the registration, but rather to slight
differences in the brain mask. This brain mask is re-created using
preproc_func_macaque or bet_macaque. Both approaches have a random component and
will therefore create slightly different results on re-running. To test
registration quality in isolation, try to provide the reference image as an
input.

EOF
}


# -------- #
# OVERHEAD
# -------- #

# if no arguments are given, or help is requested, return the usage
[[ $# -eq 0 ]] || [[ $@ =~ --help ]] && usage && exit 0

# if too few arguments given, return the usage, exit with error
[[ $# -lt 1 ]] && echo "" && >&2 printf "\nError: not enough input arguments.\n\n" && usage && exit 1

# if requested, return the background info
[[ $@ =~ --info ]] && info && exit 0


# -------- #
# SETTINGS
# -------- #

# hard-coded setting flags
flgBias=0 # 1: perform bias correction, 0: do not bias correct (default)
flgInitFromPrev=0 # 1: initialize the linear transform based on the previous slice, 0: do not initialize (default)

# ------------------------- #
# ARGUMENTS AND DEFINITIONS
# ------------------------- #

# parse the input arguments
for a in "$@" ; do
  case $a in
    --episeries=*)      epi="${a#*=}"; shift ;;
    --quality=*)        flgQuality="${a#*=}"; shift ;;
    --refimg=*)         refImgPrefab="${a#*=}"; shift ;;
    --refbrainmask=*)   refBrainMaskPrefab="${a#*=}"; shift ;;
    --refheadmask=*)    refHeadMaskPrefab="${a#*=}"; shift ;;
    --workdir=*)        workDir="${a#*=}"; shift ;;
    --betmethod=*)      flgBetMethod="${a#*=}"; shift ;;
    --t1wimg=*)         t1wImg="${a#*=}"; shift ;;
    --t1wmask=*)        t1wMask="${a#*=}"; shift ;;
    --checkreg=*)       flgCheckReg="${a#*=}"; shift ;;
    --checkregthresh=*) similarityMetricPerfect="${a#*=}"; shift ;;
    --storelinear=*)    flgStoreLinear="${a#*=}"; shift ;;
    --storewarp=*)      flgStoreWarp="${a#*=}"; shift ;;
    --maskzeros=*)      flgMaskZeros="${a#*=}"; shift ;;
    --restricthead=*)   flgRestrictHeadMaskWidth="${a#*=}"; shift ;;
    --suffixref=*)      sRef="${a#*=}"; shift ;;
    --suffixaligned=*)  sAligned="${a#*=}"; shift ;;
    --suffixbrainmask=*) sBrainMask="${a#*=}"; shift ;;
    --suffixheadmask=*) sHeadMask="${a#*=}"; shift ;;
    --suffixbiascorr=*) sBiasCorr="${a#*=}"; shift ;;
    --suffixdetrend=*)  sDetrend="${a#*=}"; shift ;;
    --debug=*)          flgDebug="${a#*=}"; shift ;;
    --debug)            flgDebug=1; shift ;; # compatibility option
    --verbose=*)        flgVerbose="${a#*=}"; shift ;;
    --verbose)          flgVerbose=1; shift ;; # compatibility option
    *)                  shift ;; # unspecified argument
  esac
done

# test for obligatory arguments
[[ -z $epi ]] && >&2 printf "\nError: Please provide an EPI timeseries input.\n\n" && exit 1

# infer debug and verbose settings
[[ -z $flgDebug ]] && flgDebug=0
[[ -z $flgVerbose ]] && [[ $flgDebug -eq 1 ]] && flgVerbose=1 || flgVerbose=0

# infer the suffixes
[[ -z $sRef ]] && sRef="_ref"
[[ -z $sAligned ]] && sAligned="_aligned"
[[ -z $sBrainMask ]] && sBrainMask="_brain_mask"
[[ -z $sHeadMask ]] && sHeadMask="_head_mask"
[[ -z $sBiasCorr ]] && sBiasCorr="_restore"
[[ -z $sDetrend ]] && sDetrend="_detrend"
sMean="_mean"
sStrict="_strict"
sRegular="_regular"
sLiberal="_liberal"

# infer EPI directory, and retrieve the absolute path
epiDir=$(cd "$(dirname $epi)" && pwd)

# remove path and extension from input image
epi=$(basename $epi)
epi=$(remove_ext $epi)

# force images to be stored in NIFTI_GZ format
FSLOUTPUTTYPE_ORIG=$FSLOUTPUTTYPE
export FSLOUTPUTTYPE=NIFTI_GZ

# test if images exist and are in the NIFTI_GZ format
for testImg in $epiDir/$epi $refImgPrefab $refBrainMaskPrefab $refHeadMaskPrefab ; do
  [[ $(imtest $testImg) -eq 0 ]] && >&2 printf "\nError: The input image\n  %s\ndoes not exist or is not in a supported format.\n\n" "$testImg" && exit 1
  [[ $(echo $testImg.* | sed "s#$testImg##g") != ".nii.gz" ]] && >&2 printf "\nError: All input images must be in NIFTI_GZ image format (*.nii.gz).\n\n" && exit 1
done

# explicitely test for the reference brain mask, if only a reference image is supplied
if [[ -n $refImgPrefab ]] && [[ -z $refBrainMaskPrefab ]] ; then
  defaultName=${refImgPrefab}${sBrainMask}
  # if the brain mask does exist, give an error
  [[ -f $defaultName.nii.gz ]] && printf "\nError: A reference image was provided, but the brain mask was not specified.\nHowever, a file with the default name does already exist\n  %s\nPlease specify the brain mask explicitly through --refbrainmask or rename this file to avoid conflict.\n\n" $defaultName  && exit 1
fi

# infer the directory holding the intermediate files
[[ -z $workDir ]] && workDir=$epiDir/work
if [[ -d $workDir ]] ; then
  flgNewWorkDir=0
  if [[ $flgDebug -ne 1 ]] ; then
    printf "\nWarning: The proposed working directory already exists\n  %s\nPlease note that files may be overwritten.\nMoreover, clean-up of intermediate files won't be possible.\n\n" "$workDir"
  fi
else
  flgNewWorkDir=1
fi

# ensure the directory exists and use absolute path
mkdir -p $workDir
workDir=$(cd $workDir && pwd)
mkdir -p $workDir/tmp

# create a working directory for the reference image
refDir=$workDir/ref
mkdir -p $refDir

# assign short-hand names
refImg=$refDir/ref
refBrainMask=${refImg}${sBrainMask}
refHeadMask=${refImg}${sHeadMask}

# infer the brain extraction method
if [[ -n $refImgPrefab ]] && [[ -r $refImgPrefab.nii.gz ]] ; then
  [[ -n $flgBetMethod ]] && printf "\nWarning: the requested brain extraction method (%s) will be ignored as a reference brain mask is already provided.\n" $flgBetMethod
  [[ -z $flgBetMethod ]] && flgBetMethod="notApplicable"
fi
[[ -z $flgBetMethod ]] && flgBetMethod="T1W"
flgBetMethod=$(echo $flgBetMethod | tr '[a-z]' '[A-Z]')

# test whether the T1w image and mask are specified
if [[ $flgBetMethod == "T1W" ]] ; then
  if [[ -z $t1wImg ]] || [[ -z $t1wMask ]] ; then
    >&2 printf "\nError: Please provide a T1w image and mask for the brain extraction.\n Alternatively, select --betmethod=EPI.\n\n" && exit 1
  fi
  for testImg in $t1wImg $t1wMask ; do
    [[ $(imtest $testImg) -eq 0 ]] && >&2 printf "\nError: The input image\n  %s\ndoes not exist or is not in a supported format.\n\n" "$testImg" && exit 1
    [[ $(echo $testImg.* | sed "s#$testImg##g") != ".nii.gz" ]] && >&2 printf "\nError: All input images must be in NIFTI_GZ image format (*.nii.gz).\n\n" && exit 1
  done
fi

# infer whether to store the linear and/or non-linear (warp) transformations
[[ -z $flgStoreLinear ]] && flgStoreLinear=1
[[ -z $flgStoreWarp ]] && flgStoreWarp=1
if [[ $flgStoreLinear -eq 1 ]] || [[ $flgStoreWarp -eq 1 ]] ; then
  transDir=$(dirname $epiDir)/transform
  mkdir -p $transDir
fi
if [[ $flgStoreLinear -eq 1 ]] ; then
  reportFileYScale=$transDir/yScale.txt && > $reportFileYScale
  reportFileYTranslate=$transDir/yTranslate.txt && > $reportFileYTranslate
fi

# infer whether to ignore (mask out) zero voxels far outside head
[[ -z $flgMaskZeros ]] && flgMaskZeros=1

# infer whether to exclude lateral sides of the head outside the brain
[[ -z $flgRestrictHeadMaskWidth ]] && flgRestrictHeadMaskWidth=1 # 1: restrict the x-range at a fixed width for all slices (recommended), 2: adapt the restriction for each slice based on the brain mask (not recommended), 0: do not restrict

# infer whether to check the quality of the linear and non-linear transformations
[[ -z $flgCheckReg ]] && flgCheckReg=1

# create a directory to store the report(s)
mkdir -p $epiDir/report
reportFileProgress=$epiDir/report/progress.txt && > $reportFileProgress
if [[ $flgCheckReg -eq 1 ]] ; then
  reportFileOrig=$epiDir/report/similarityMetricOrig.txt && > $reportFileOrig
  reportFileLinear=$epiDir/report/similarityMetricLinear.txt && > $reportFileLinear
  reportFileWarp=$epiDir/report/similarityMetricWarp.txt && > $reportFileWarp
  #reportFileNeighborhoodWarp=$epiDir/report/similarityMetricNeighborhoodWarp.txt && > $reportFileNeighborhoodWarp
fi

# infer requested registration quality
[[ -z $flgQuality ]] && flgQuality=2
[[ ! $flgQuality =~ ^[0-9]+$ ]] && >&2 printf "\nError: Please specify --quality=<int> as an interger, either 0, 1, 2, or 3.\n\n" && exit 1

# B-spline knot-spacing:
# 16 = 8x8
# 26 = 5x5

# set registration parameters based on requested quality
similarityMetricOkay="-0.75"
similarityMetricGood="-0.85"
case $flgQuality in
  0 )
    similarityMetricPerfectDefault="-0.95"
    transformLinear="[0.1]"
    convergenceLinear="[5,1e-4,2]"
    shrinkFactorsLinear="2"
    smoothingSigmasLinear="1vox"
    transformNonLinear="[0.1,1x5,0]"
    convergenceNonLinear="[3,1e-4,2]"
    shrinkFactorsNonLinear="2"
    smoothingSigmasNonLinear="1vox"
    ;;
  1 )
    similarityMetricPerfectDefault="-0.97"
    transformLinear="[0.1]"
    convergenceLinear="[15x10,1e-6,4]"
    shrinkFactorsLinear="2x1"
    smoothingSigmasLinear="1x0vox"
    transformNonLinear="[0.1,1x5,0]"
    convergenceNonLinear="[15,1e-6,4]"
    shrinkFactorsNonLinear="1"
    smoothingSigmasNonLinear="0vox"
    ;;
  2 )
    similarityMetricPerfectDefault="-1"
    transformLinear="[0.1]"
    convergenceLinear="[50x20,1e-6,4]"
    shrinkFactorsLinear="2x1"
    smoothingSigmasLinear="1x0vox"
    transformNonLinear="[0.1,1x5,0]"
    convergenceNonLinear="[30,1e-6,4]"
    shrinkFactorsNonLinear="1"
    smoothingSigmasNonLinear="0vox"
    ;;
  * )
    similarityMetricPerfectDefault="-1"
    transformLinear="[0.1]"
    convergenceLinear="[50x20,1e-6,4]"
    shrinkFactorsLinear="2x1"
    smoothingSigmasLinear="1x0vox"
    transformNonLinear="[0.1,1x5,0]"
    convergenceNonLinear="[50,1e-8,6]"
    shrinkFactorsNonLinear="1"
    smoothingSigmasNonLinear="0vox"
    ;;
esac

# set the similarityMetricPerfect based on the arguments or the default value
[[ -z $similarityMetricPerfect ]] && similarityMetricPerfect=$similarityMetricPerfectDefault

# count the number of volumes in the EPI timeseries
nVol=$(fslval $epiDir/$epi dim4)
[[ $nVol -lt 2 ]] && >&2 printf "\nError: The input image\n  %s\nshould be a 4D timeseries.\n\n" "$epiDir/$epi" && exit 1


# ------------------------ #
# CREATE A REFERENCE IMAGE
# ------------------------ #
if [[ -n $refImgPrefab ]] ; then
  echo "" | tee -a $reportFileProgress
  echo "EPI TIMESERIES TO VOLUMES" | tee -a $reportFileProgress

  # copy the explicitly specified reference image to the working directory
  imcp $refImgPrefab $refImg

else

  echo "" | tee -a $reportFileProgress
  echo "CREATING A REFERENCE IMAGE" | tee -a $reportFileProgress
  echo "  finding best volumes in the timeseries" | tee -a $reportFileProgress

  # decide how many volumes correspond to 20% and 40% of the total
  [[ $nVol -lt 5 ]] && printf "\nWarning: The input image\n  %s\nhas less than 5 volumes in the timeseries, this might hamper the quality of the reference image.\n\n" "$epiDir/$epi"
  nRefLiberal=$(echo $nVol | awk '{$0=0.4*$0; printf "%d\n", ($0+=$0<0?-0.5:0.5) }')
  nRefStrict=$(echo $nRefLiberal | awk '{$0=0.5*$0; printf "%d\n", ($0+=$0<0?-0.5:0.5) }')
  [[ $nRefLiberal -lt 1 ]] && nRefLiberal=1
  [[ $nRefStrict -lt 1 ]] && nRefStrict=1

  # initialize volume selection for the reference
  mkdir -p ${refImg}Volumes
  fslsplit $epiDir/$epi ${refImg}Volumes/vol -t
  compareSlicesTmp=${refImg}Volumes/compareSlicesTmp.txt
  compareSlices=${refImg}Volumes/compareSlices.txt
  compareVolumes=${refImg}Volumes/compareVolumes.txt
  compareCombined=${refImg}Volumes/compareCombined.txt

  # calculate how much slices look like their neighbours for each volume
  > $compareSlicesTmp
  for v in $(seq 0 $((nVol-1))) ; do
    vol=${refImg}Volumes/vol$(printf %04d $v)
    # perform mean filtering across slices
    fslmaths $vol -kernel boxv3 1 1 3 -fmean ${vol}_sliceInterp
    # compare slices within volume using NormalizedCorrelation (alternative: Mattes mutual-information)
    ImageMath 3 ${vol}out.nii.gz NormalizedCorrelation ${vol}.nii.gz ${vol}_sliceInterp.nii.gz  >> $compareSlicesTmp # Mattes: {Optional-number-bins=32} {Optional-image-mask}
  done

  # select the volumes with the least variability over slices to create a reference
  nl $compareSlicesTmp | sort -nk2 | head -$nRefLiberal > $compareSlices
  echo $compareSlicesTmp | xargs rm
  refList=$(awk '{printf "'${refImg}'Volumes/vol%04d\n", $1-1}' < $compareSlices)
  fslmerge -t ${refImg}4D $refList
  fslmaths ${refImg}4D -Tmean ${refImg}

  # then check for variability across time with respect to the hifi average
  > $compareVolumes
  for vol in $refList ; do
    # compare volumes with reference using NormalizedCorrelation (alternative: Mattes mutual-information)
    ImageMath 3 ${vol}out.nii.gz NormalizedCorrelation ${vol}.nii.gz ${refImg}.nii.gz  >> $compareVolumes # Mattes: {Optional-number-bins=32} {Optional-image-mask}
  done

  # combine the variability across slices (weight=0.66) and across volumes (weight=0.33) into one metric
  paste $compareSlices $compareVolumes | awk '{print $1 " " ($2*2+$3)/3}' > $compareCombined

  # select the best half of the intermediate reference images to create a new average reference
  refList=$(cat $compareCombined | sort -nk2 | head -$nRefStrict | awk '{printf "'${refImg}'Volumes/vol%04d\n", $1-1}')
  fslmerge -t ${refImg}4D $refList
  fslmaths ${refImg}4D -Tmean ${refImg}

#   # run some quick motion correction on those images
  echo "  roughly aligning and averaging those volumes" | tee -a $reportFileProgress
  antsMotionCorr \
    --dimensionality 3 \
    --output [${refImg}4D_, ${refImg}4D${sAligned}.nii.gz,${refImg}.nii.gz] \
    --useFixedReferenceImage 1 \
    --useScalesEstimator 1 \
    --n-images $nRefStrict \
    --transform Affine[0.1] \
    --metric MI[${refImg}.nii.gz, ${refImg}4D.nii.gz, 1, 32, Regular, 0.1] \
    --iterations 15x3 \
    --smoothingSigmas 1x0 \
    --shrinkFactors 2x1 \
    --verbose $flgVerbose
  [[ $flgVerbose -eq 1 ]] && echo "" && echo ""

  # fix the corrupted header after ANTs (reset slice thickness)
  fslcpgeom "$(echo "$refList" | head -1)" $refImg

  # copy the reference image back to the EPI directory
  imcp ${refImg} $epiDir/${epi}${sRef}

  # clean-up the intermediate files
  [[ $flgDebug -ne 1 ]] && rm -rf ${refImg}Volumes

fi

# --------------------------- #
# PREPROC THE REFERENCE IMAGE
# --------------------------- #

#create an average as a reference?
echo "" | tee -a $reportFileProgress
echo "PREPARING THE REFERENCE VOLUME" | tee -a $reportFileProgress

# copy or create the reference brain mask
if [[ -n $refBrainMaskPrefab ]] ; then

  # copy the explicitly specified reference brain mask to the working directory
  imcp $refBrainMaskPrefab $refBrainMask

else

  # (re-)create a brain mask for the reference image
  echo "  extracting the brain" | tee -a $reportFileProgress
  if [[ $flgBetMethod == "T1W" ]] ; then
    # based on the brain mask of the T1w image
    sh $MRCATDIR/pipelines/PreprocFunc_macaque/RegisterFuncStruct_macaque.sh --epiimg=$refImg --t1wimg=$t1wImg --t1wmask=$t1wMask --extract --quality=1
  else
    # based on the EPI image alone
    sh $MRCATDIR/core/bet_macaque.sh $refImg -t T2star -s bet -m
  fi

  # ensure name is as requested and copy to EPI timeseries directory
  [[ $sBrainMask != "_brain_mask" ]] && immv ${refImg}_brain_mask ${refBrainMask}
  imcp ${refBrainMask} $epiDir/${epi}${sRef}${sBrainMask}

fi

# perform initial bias correction if requested (and reference image is not provided)
if [[ -z $refImgPrefab ]] && [[ $flgBias -eq 1 ]] ; then
  echo "  bias-correction" | tee -a $reportFileProgress

  # bias correction
  N4BiasFieldCorrection \
    --image-dimensionality 3 \
    --input-image ${refImg}.nii.gz \
    --mask-image ${refBrainMask}.nii.gz \
    --shrink-factor 4 \
    --convergence [50x50x50x50,0.0000001] \
    --output ${refImg}_4reg.nii.gz \
    --verbose $flgVerbose
  [[ $flgVerbose -eq 1 ]] && echo "" && echo ""

  # fix the corrupted header after ANTs (reset slice thickness)
  fslcpgeom ${refImg} ${refImg}_4reg

  # copy to the EPI timeseries directory
  imcp ${refImg}_4reg $epiDir/${epi}${sRef}${sBiasCorr}

else

  # don't bias correct, simply copy
  imcp ${refImg} ${refImg}_4reg

fi


# copy or create the reference head mask
if [[ -n $refHeadMaskPrefab ]] ; then

  # copy the explicitly specified reference head mask to the working directory
  imcp $refHeadMaskPrefab ${refHeadMask}${sStrict}

else

  echo "  creating a whole-head mask" | tee -a $reportFileProgress
  imcp ${refImg} ${refImg}_4headmask

  # create a whole-head mask based on a sensible average intensity of brain voxels
  # erode the brain mask to ensure only brain voxels are considered
  ImageMath 3 ${refBrainMask}_ero.nii.gz ME ${refBrainMask}.nii.gz 3
  # find a liberal head mask: set the whole-head intensity threshold at 25% of the mean brain intensity
  thrLiberal=$(fslstats ${refImg}_4headmask -k ${refBrainMask}_ero -M | awk '{print $1/4}')
  # find a strict head mask: set the whole-head intensity threshold at 50% of the mean brain intensity
  thrStrict=$(fslstats ${refImg}_4headmask -k ${refBrainMask}_ero -M | awk '{print $1/2}')

  # create a liberal and a strict whole-head mask based on those intensity
  for suffix in $sLiberal $sStrict ; do
    # select the rigth threshold value
    [[ $suffix == "$sLiberal" ]] && thr=$thrLiberal || thr=$thrStrict
    # threshold the whole image to find the head
    ThresholdImage 3 ${refImg}_4headmask.nii.gz ${refHeadMask}${suffix}.nii.gz $thr inf 1 0
    ImageMath 3 ${refHeadMask}${suffix}.nii.gz GetLargestComponent ${refHeadMask}${suffix}.nii.gz
    ImageMath 3 ${refHeadMask}${suffix}.nii.gz FillHoles ${refHeadMask}${suffix}.nii.gz 2
    # alternate dilation and erosion with a gaussion kernel for a smooth result
    ImageMath 3 ${refHeadMask}${suffix}.nii.gz G ${refHeadMask}${suffix}.nii.gz 1.5
    ThresholdImage 3 ${refHeadMask}${suffix}.nii.gz ${refHeadMask}${suffix}.nii.gz 0.2 inf 1 0
    ImageMath 3 ${refHeadMask}${suffix}.nii.gz G ${refHeadMask}${suffix}.nii.gz 1.5
    ThresholdImage 3 ${refHeadMask}${suffix}.nii.gz ${refHeadMask}${suffix}.nii.gz 0.6 inf 1 0
    # ensure all brain voxels are included
    ImageMath 3 ${refHeadMask}${suffix}.nii.gz addtozero ${refHeadMask}${suffix}.nii.gz ${refBrainMask}.nii.gz
    # fix the corrupted header after ANTs (reset slice thickness)
    fslcpgeom ${refBrainMask} ${refHeadMask}${suffix}
    # bias correct after the first mask definition
    if [[ $suffix == "$sLiberal" ]] ; then
      echo "    bias-correction for the whole head" | tee -a $reportFileProgress
      N4BiasFieldCorrection \
        --image-dimensionality 3 \
        --input-image ${refImg}.nii.gz \
        --mask-image ${refHeadMask}${suffix}.nii.gz \
        --shrink-factor 4 \
        --convergence [50x50x50x50,0.0000001] \
        --output ${refImg}_4headmask.nii.gz \
        --verbose $flgVerbose
      [[ $flgVerbose -eq 1 ]] && echo "" && echo ""
      flgBiasCorrDone=1
    fi
  done

  # The most difficult part is the back of the brain: the superior slices are
  # easily misregistered because of signal loss, while the inferior slices are
  # often misaligned as a result of large distortions in the neck. In the neck
  # region, it looks like the distortion is not even uniform along the x-axis,
  # with more stretching along the y-axis in the middle of the image, and less on
  # the sides. However, I force the registration to fit a single BSpline to avoid
  # overfitting in the rest of the brain. To avoid the registration getting
  # side-tracked by the distortions in the neck, and in the process
  # over-compensating the distortion along the midline, I strip the neck away from
  # the head mask. This is an elaborate procedure, but critical.

  # retrieve the image dimensions
  xSize=$(fslval ${refBrainMask} dim1)
  ySize=$(fslval ${refBrainMask} dim2)
  zSize=$(fslval ${refBrainMask} dim3)

  # calculate sum of voxel intensities within brain mask, for each slice
  echo "    calculating brain area per slice" | tee -a $reportFileProgress
  nVox=$(echo $xSize $ySize $zSize | awk '{print $1*$2*$3}')
  > $workDir/tmp/area.txt
  for z in $(seq 0 $((zSize-1))) ; do
    fslmaths $refImg -mas ${refBrainMask} -roi 0 -1 0 -1 $z 1 0 -1 ${refImg}_tmpSlice
    fslstats ${refImg}_tmpSlice -m | awk -v n=$nVox '{printf "%12.2f\n", $1*n}' >> $workDir/tmp/area.txt
  done
  awk 'FNR==NR{max=($1+0>max)?$1:max;next} {print FNR-1,$1/max}' $workDir/tmp/area.txt $workDir/tmp/area.txt > $workDir/tmp/areaNorm.txt
  awk '{a[i++]=$0} END {for (j=i-1; j>=0;) print a[j--] }' $workDir/tmp/areaNorm.txt > $workDir/tmp/areaNormRev.txt

  # use three methods to define the middle slice of the brain
  # first, find the slice with the longest posterior-anterior axis in the brain
  fslmaths ${refBrainMask} -Ymean -mul $ySize ${refBrainMask}_length
  midSliceA=$(fslstats ${refBrainMask}_length -x | awk '{print $3}')
  # second, find the slice with the largest area
  midSliceB=$(awk '($2==1){print $1}' $workDir/tmp/areaNorm.txt)
  # third, find the centre-of-gravity
  midSliceC=$(fslstats $refBrainMask -C | awk '{print $3}')
  # take the average of these three methods
  midSlice=$(printf "%s\n" $midSliceA $midSliceB $midSliceC | awk ' { sum+=$0 } END { avg=sum/NR; printf("%d\n",avg+=avg<0?-0.5:0.5) }')

  # create a mask that excludes the neck: first find the back of the brain
  echo "    excluding the neck" | tee -a $reportFileProgress
  fslmaths ${refBrainMask} -mul 0 -add 1 -roi 0 -1 0 -1 $midSlice 1 0 -1 ${refHeadMask}_excludeBack
  yBackBrain=$(fslstats ${refBrainMask} -k ${refHeadMask}_excludeBack -w | awk '{print $3}')

  # the top half of the head is accepted from three voxel behind the brain
  fslmaths ${refHeadMask}_excludeBack -mul 0 -add 1 -roi 0 -1 $((yBackBrain-3)) -1 $((midSlice+1)) -1 0 -1 ${refHeadMask}_excludeBack

  # descend from the middle slice downwards, accept in a forward facing slope
  for z in $(seq $midSlice -1 0) ; do
    # only include parts that are in front of the back of the brain
    fslmaths ${refHeadMask}_excludeBack -mul 0 -add 1 -roi 0 -1 $yBackBrain -1 $z 1 0 -1 -add ${refHeadMask}_excludeBack -bin ${refHeadMask}_excludeBack
    # and in a forward facing slope (increment yBackBrain with each slice)
    ((++yBackBrain))
  done

  # exclude the neck (and posterior ghosting) from the head mask, but keep the brain
  fslmaths ${refHeadMask}${sStrict} -mas ${refHeadMask}_excludeBack -add ${refBrainMask} -bin ${refHeadMask}${sStrict}

  # find the midline of the brain
  xMidVox=$(fslstats ${refBrainMask} -C | awk '{printf("%d\n",$1+=$0<0?-0.5:0.5)}') # in vox
  xMidMM=$(fslstats ${refBrainMask} -c | awk '{ print $1 }') # in mm

  # allow option to restrict x-range to limit the influence of the sides of the head
  if [[ $flgRestrictHeadMaskWidth -eq 1 ]] ; then
    # restrict the x-range according to a fixed width (for all slices)

    # determine the width of the brain
    fslmaths ${refBrainMask} -Xmean -mul $xSize ${refBrainMask}_width
    brainWidth=$(fslstats ${refBrainMask}_width -P 95)
    # restrict head mask to 120% of the brain width
    halfWidth=$(echo $brainWidth | awk '{ halfWidth=$1*0.6; printf("%d\n",halfWidth+=halfWidth<0?-0.5:0.5) }')
    fslmaths ${refHeadMask}${sStrict} -mul 0 -add 1 -roi $((xMidVox-halfWidth)) $((halfWidth*2+1)) 0 -1 0 -1 0 -1 ${refHeadMask}_xRestrict
    fslmaths ${refHeadMask}${sStrict} -mas ${refHeadMask}_xRestrict ${refHeadMask}${sStrict}

  elif [[ $flgRestrictHeadMaskWidth -eq 2 ]] ; then
    # restrict the x-range relative to the brain mask (with a minimum)

    # widen the brain mask to 120%
    xScale=1.2
    # find the translation to correct for the origin offset after scaling
    xVoxSize=$(fslval ${refHeadMask}${sStrict} pixdim1)
    xTranslate=$(echo $xVoxSize $xMidMM $xScale | awk '{ print $1+$2-($2*$3) }')

    # write a transformation matrix
    cat >$refDir/xscale.mat <<EOL
$xScale 0 0 $xTranslate
0 1 0 0
0 0 1 0
0 0 0 1
EOL
    # rescale the brain mask along the x-axis
    flirt -in ${refBrainMask} -ref ${refBrainMask} -applyxfm -init $refDir/xscale.mat -out ${refHeadMask}_xRestrict
    fslmaths ${refHeadMask}_xRestrict -add ${refBrainMask} -bin ${refHeadMask}_xRestrict

    # take a maximum projection along the y-axis
    fslmaths ${refHeadMask}_xRestrict -Ymax -bin ${refHeadMask}_xRestrict
    fslswapdim ${refHeadMask}_xRestrict x z -y ${refHeadMask}_xRestrict
    ImageMath 2 ${refHeadMask}_xRestrict.nii.gz ReplicateImage ${refHeadMask}_xRestrict.nii.gz $ySize 1 0
    fslswapdim ${refHeadMask}_xRestrict x -z y ${refHeadMask}_xRestrict
    fslcpgeom ${refHeadMask}${sStrict} ${refHeadMask}_xRestrict

    # set a minimum x-range at 31 voxels
    halfWidth=15
    fslmaths ${refHeadMask}${sStrict} -mul 0 -add 1 -roi $((xMidVox-halfWidth)) $((halfWidth*2+1)) 0 -1 0 -1 0 -1 -add ${refHeadMask}_xRestrict -bin ${refHeadMask}_xRestrict
    fslmaths ${refHeadMask}${sStrict} -mas ${refHeadMask}_xRestrict ${refHeadMask}${sStrict}

  fi

  # identify slices with big enough brain contributions
  echo "    dilating and combining" | tee -a $reportFileProgress
  idxInferiorSlice=$(awk '($2>0.05){print $1; exit}' $workDir/tmp/areaNorm.txt)
  idxSuperiorSlice=$(awk '($2>0.1){print $1; exit}' $workDir/tmp/areaNormRev.txt)
  idxTopSlice=$(awk '($2>0.01){print $1; exit}' $workDir/tmp/areaNormRev.txt)

  # dilate the mask in the anterior direction
  yDil=3
  fslroi $refImg ${refHeadMask}_anterior 0 1 0 $((yDil*2+1)) 0 1
  fslmaths ${refHeadMask}_anterior -mul 0 -add 1 -roi 0 -1 0 $((yDil+1)) 0 -1 0 -1 ${refHeadMask}_anterior
  fslmaths ${refHeadMask}${sStrict} -kernel file ${refHeadMask}_anterior -dilF ${refHeadMask}${sStrict}

  # dilate the mask towards the midline to achieve CSF coverage
  xDil=6
  # dilate leftwards (but restrict to the right hemisphere)
  fslroi $refImg ${refHeadMask}_left 0 $((xDil*2+1)) 0 1 0 1
  fslmaths ${refHeadMask}_left -mul 0 -add 1 -roi 0 $((xDil+1)) 0 -1 0 -1 0 -1 ${refHeadMask}_left
  fslmaths ${refHeadMask}${sStrict} -kernel file ${refHeadMask}_left -dilF -roi 0 $((xMidVox+1)) 0 -1 0 -1 0 -1 ${refHeadMask}_left
  # dilate rightwards (but restrict to the left hemisphere)
  fslroi $refImg ${refHeadMask}_right 0 $((xDil*2+1)) 0 1 0 1
  fslmaths ${refHeadMask}_right -mul 0 -add 1 -roi $xDil -1 0 -1 0 -1 0 -1 ${refHeadMask}_right
  fslmaths ${refHeadMask}${sStrict} -kernel file ${refHeadMask}_right -dilF -roi $xMidVox -1 0 -1 0 -1 0 -1 ${refHeadMask}_right
  # combine the leftward and rightward dilations
  fslmaths ${refHeadMask}${sStrict} -add ${refHeadMask}_left -add ${refHeadMask}_right -bin ${refHeadMask}${sStrict}

  # polish the head mask
  ImageMath 3 ${refHeadMask}${sStrict}.nii.gz GetLargestComponent ${refHeadMask}${sStrict}.nii.gz
  ImageMath 3 ${refHeadMask}${sStrict}.nii.gz FillHoles ${refHeadMask}${sStrict}.nii.gz 2
  # alternate dilation and erosion with a gaussion kernel for a smooth result
  ImageMath 3 ${refHeadMask}${sStrict}.nii.gz G ${refHeadMask}${sStrict}.nii.gz 1.5
  ThresholdImage 3 ${refHeadMask}${sStrict}.nii.gz ${refHeadMask}${sStrict}.nii.gz 0.4 inf 1 0
  ImageMath 3 ${refHeadMask}${sStrict}.nii.gz G ${refHeadMask}${sStrict}.nii.gz 1.5
  ThresholdImage 3 ${refHeadMask}${sStrict}.nii.gz ${refHeadMask}${sStrict}.nii.gz 0.6 inf 1 0
  # ensure all brain voxels are included
  ImageMath 3 ${refHeadMask}${sStrict}.nii.gz addtozero ${refHeadMask}${sStrict}.nii.gz ${refBrainMask}.nii.gz
  # fix the corrupted header after ANTs (reset slice thickness)
  fslcpgeom ${refBrainMask} ${refHeadMask}${sStrict}
  # ensure the x-range is enforced
  [[ $flgRestrictHeadMaskWidth -gt 0 ]] && fslmaths ${refHeadMask}${sStrict} -mas ${refHeadMask}_xRestrict ${refHeadMask}${sStrict}

  # dilate the bottom of the mask to achieve a reasonable size in all slices
  fslroi $refImg ${refHeadMask}_inferior 0 1 0 1 0 $((idxInferiorSlice*2+1))
  fslmaths ${refHeadMask}_inferior -mul 0 -add 1 -roi 0 -1 0 -1 $idxInferiorSlice -1 0 -1 ${refHeadMask}_inferior
  fslmaths ${refHeadMask}${sStrict} -roi 0 -1 0 -1 0 $((idxInferiorSlice+1)) 0 -1 -kernel file ${refHeadMask}_inferior -dilF ${refHeadMask}_inferior

  # dilate the top of the mask to achieve a reasonable size in all slices
  fslroi $refImg ${refHeadMask}_superior 0 1 0 1 0 $(($((zSize-idxSuperiorSlice))*2+1))
  fslmaths ${refHeadMask}_superior -mul 0 -add 1 -roi 0 -1 0 -1 0 $(($((zSize-idxSuperiorSlice))+1)) 0 -1 ${refHeadMask}_superior
  fslmaths ${refHeadMask}${sStrict} -roi 0 -1 0 -1 $idxSuperiorSlice -1 0 -1 -kernel file ${refHeadMask}_superior -dilF ${refHeadMask}_superior

  # combine the anterior and medial dilated head mask with the inferior and superior dilations
  fslmaths ${refHeadMask}${sStrict} -add ${refHeadMask}_inferior -add ${refHeadMask}_superior -bin ${refHeadMask}${sStrict}

  # store the head mask for inspection in the EPI timeseries folder
  imcp ${refHeadMask}${sStrict} $epiDir/${epi}${sRef}${sHeadMask}

fi

# dilate the head mask mask in the posterior direction to capture most distorted volumes
fslroi $refImg ${refHeadMask}${sRegular} 0 1 0 11 0 1
fslmaths ${refHeadMask}${sRegular} -mul 0 -add 1 -roi 0 -1 5 6 0 -1 0 -1 ${refHeadMask}${sRegular}
fslmaths ${refHeadMask}${sStrict} -kernel file ${refHeadMask}${sRegular} -dilF ${refHeadMask}${sRegular}

# and dilate even further for a liberal head mask that captures all distored volumes
fslroi $refImg ${refHeadMask}${sLiberal} 0 1 0 21 0 1
fslmaths ${refHeadMask}${sLiberal} -mul 0 -add 1 -roi 0 -1 10 11 0 -1 0 -1 ${refHeadMask}${sLiberal}
fslmaths ${refHeadMask}${sStrict} -kernel file ${refHeadMask}${sLiberal} -dilF ${refHeadMask}${sLiberal}


# perform bias correction or not
if [[ $flgBias -eq 1 ]] ; then

  # bias correction
  N4BiasFieldCorrection \
    --image-dimensionality 3 \
    --input-image ${refImg}_4reg.nii.gz \
    --mask-image ${refHeadMask}${sStrict}.nii.gz \
    --shrink-factor 4 \
    --convergence [50x50x50x50,0.0000001] \
    --output ${refImg}_4reg.nii.gz \
    --verbose $flgVerbose
  [[ $flgVerbose -eq 1 ]] && echo "" && echo ""

  # fix the corrupted header after ANTs (reset slice thickness)
  fslcpgeom $refImg ${refImg}_4reg

  # extract the head from the bias-corrected image
  fslmaths ${refImg}_4reg -mas ${refHeadMask}${sStrict} ${refImg}_4reg

else

  # don't bias correct, simply extract the head
  fslmaths $refImg -mas ${refHeadMask}${sStrict} ${refImg}_4reg

fi

# dilate the masks to ignore voxels far out the relevant region (brain+head)
vDil=3
ImageMath 3 ${refHeadMask}${sStrict}_dil.nii.gz MD ${refHeadMask}${sStrict}.nii.gz $vDil
ImageMath 3 ${refHeadMask}${sRegular}_dil.nii.gz MD ${refHeadMask}${sRegular}.nii.gz $vDil
ImageMath 3 ${refHeadMask}${sLiberal}_dil.nii.gz MD ${refHeadMask}${sLiberal}.nii.gz $vDil

# extract slices
echo "  extracting slices of the reference image" | tee -a $reportFileProgress
nSlice=$(fslval ${refImg}_4reg dim3)
fslsplit ${refImg}_4reg ${refImg}_4reg_slice -z
fslsplit ${refHeadMask}${sStrict} ${refHeadMask}${sStrict}_slice -z
fslsplit ${refHeadMask}${sStrict}_dil ${refHeadMask}${sStrict}_dil_slice -z
fslsplit ${refHeadMask}${sRegular} ${refHeadMask}${sRegular}_slice -z
fslsplit ${refHeadMask}${sRegular}_dil ${refHeadMask}${sRegular}_dil_slice -z
fslsplit ${refHeadMask}${sLiberal} ${refHeadMask}${sLiberal}_slice -z
fslsplit ${refHeadMask}${sLiberal}_dil ${refHeadMask}${sLiberal}_dil_slice -z


# ------------------------- #
# CORRECT MOTION DISTORTION
# ------------------------- #

# register all volumes to the reference
echo "" | tee -a $reportFileProgress
echo "CORRECTING FOR MOTION DISTORTION" | tee -a $reportFileProgress
printf "  number of volumes: % 4d\n" $nVol | tee -a $reportFileProgress
# start a timer
#SECONDS=0

# split the EPI 4D timeseries in volumes
fslsplit $epiDir/$epi $workDir/vol

# loop over volumes
[[ $flgVerbose -ne 1 ]] && printf "  working on volume: "
for v in $(seq 0 $((nVol-1))) ; do
  # report the volume index
  if [[ $flgVerbose -eq 1 ]] ; then
    echo "  volume $v" | tee -a $reportFileProgress
  else
    # 0-based for the progress report file
    echo "  volume $v" >> $reportFileProgress
    # 1-based for human eyes in the terminal
    [[ $v -gt 0 ]] && printf "\b\b\b\b"
    printf "% 4d" $((v+1))
  fi
  vol="$(printf vol%04d $v)"

  # create a working directory for the current volume
  volDir=$workDir/$vol
  mkdir -p $volDir

  # move the volume
  immv $workDir/$vol $volDir/$vol

  # extract slices
  fslsplit $volDir/$vol $volDir/${vol}_slice -z

  # now run the registration slice by slice
  for s in $(seq 0 $((nSlice-1))) ; do
    [[ $flgVerbose -eq 1 ]] && echo "    slice $s" | tee -a $reportFileProgress && flgReportSlice=1 || flgReportSlice=0
    slice="$(printf slice%04d $s)"

    # set the reference and volume slices for registration
    ref=${refImg}_4reg_$slice
    maskStrict=${refHeadMask}${sStrict}_$slice
    maskStrictDil=${refHeadMask}${sStrict}_dil_$slice
    maskRegular=${refHeadMask}${sRegular}_$slice
    maskRegularDil=${refHeadMask}${sRegular}_dil_$slice
    maskLiberal=${refHeadMask}${sLiberal}_$slice
    maskLiberalDil=${refHeadMask}${sLiberal}_dil_$slice
    source=$volDir/${vol}_$slice

    # calculate similarity of the original slice to the reference
    flgSkipReg=0
    if [[ $flgCheckReg -eq 1 ]] ; then
      similarityMetricOriginal=$(ImageMath 2 ${source}_out.nii.gz NormalizedCorrelation ${source}.nii.gz ${ref}.nii.gz $maskStrict.nii.gz)

      # check whether the original match is already really good, if so, skip the registration and keep the original
      if [[ $(echo $similarityMetricOriginal $similarityMetricPerfect | awk '($1<$2){ print 1 }') -eq 1 ]] ; then
        flgSkipReg=1
        [[ $flgReportSlice -ne 1 ]] && echo "    slice $s" && flgReportSlice=1
        printf "      original is already a very good match, r-value: %.4f\n" $similarityMetricOriginal >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
        echo "      accepting as it is and skipping registration" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
      fi

    fi

    # if the original match was found to be good enough, or if there is no brain
    # in this slice, don't register, just copy and continue
    if [[ $flgSkipReg -eq 1 ]] || [[ $s -gt $idxTopSlice ]] ; then
      imcp $source ${source}${sAligned}
      # report
      if [[ $flgCheckReg -eq 1 ]] ; then
        printf "1\t" >> $reportFileOrig
        printf "1\t" >> $reportFileLinear
        printf "1\t" >> $reportFileWarp
        #printf "1\t" >> $reportFileNeighborhoodWarp
      fi
      # store transformations
      [[ $flgStoreLinear -eq 1 ]] && printf "1\t" >> $reportFileYScale && printf "0\t" >> $reportFileYTranslate
      if [[ $flgStoreWarp -eq 1 ]] ; then
        warpField=$transDir/warpField_${vol}_$slice.nii.gz
        displacementField=$transDir/displacementField_${vol}_$slice.nii.gz
        fslmaths $source -mul 0 $warpField
        imcp $warpField $displacementField
      fi
      # continue to the next slice/volume
      continue
    fi

    # perform bias correction or not
    if [[ $flgBias -eq 1 ]] && [[ $s -lt $idxSuperiorSlice ]] ; then
      # bias correction
      N4BiasFieldCorrection \
        --image-dimensionality 2 \
        --input-image $source.nii.gz \
        --mask-image $maskLiberal.nii.gz \
        --shrink-factor 4 \
        --convergence [50x50x50x50,0.0000001] \
        --bspline-fitting [1x1] \
        --output ${source}_restore.nii.gz \
        --verbose $flgVerbose
      [[ $flgVerbose -eq 1 ]] && echo "" && echo ""

      # fix the corrupted header after ANTs (reset slice thickness)
      fslcpgeom $source ${source}_restore

    fi

    # set the head mask based on the quality of the original match
    # When slices are strongly distored the mask for the moving source image is
    # dilated posteriorly. However, including too many non-brain voxels in the
    # back distracts the registration when distortions are small, so a more
    # constrained mask is appropriate. These settings have been tested in a
    # small sample, but not extensively. There is a good possibility that tweaks
    # in the degree of dilation and the values of $similarityMetricGood and
    # $similarityMetricOkay might improve the overall registration.
    if [[ $flgCheckReg -eq 1 ]] && [[ $(echo $similarityMetricOriginal $similarityMetricGood | awk '($1<$2){ print 1 }') -eq 1 ]] ; then
      maskSource=$maskStrict
      maskSourceDil=$maskStrictDil
    elif [[ $flgCheckReg -eq 1 ]] && [[ $(echo $similarityMetricOriginal $similarityMetricOkay | awk '($1<$2){ print 1 }') -eq 1 ]] ; then
      maskSource=$maskRegular
      maskSourceDil=$maskRegularDil
    else
      maskSource=$maskLiberal
      maskSourceDil=$maskLiberalDil
    fi

    # extract the head
    if [[ $flgBias -eq 1 ]] && [[ $s -lt $idxSuperiorSlice ]] ; then
      fslmaths ${source}_restore -mas $maskSource ${source}_4reg
    else
      fslmaths $source -mas $maskSource ${source}_4reg
    fi

    # set masks to ignore zero voxels outside of the relevant region (brain+head)
    if [[ $flgMaskZeros -eq 1 ]] ; then
      masks="--masks [$maskStrictDil.nii.gz,$maskSourceDil.nii.gz]"
    else
      masks=""
    fi

    # initialize the transform from the previous slice (please note the interleaved acquisition)
    sPrev=$((s-2))
    if [[ $flgInitFromPrev -eq 1 ]] && [[ $sPrev -ge 0 ]]; then
      sourcePrev=$volDir/${vol}_slice$(printf %04d $sPrev)
      initTransform="${sourcePrev}_0GenericAffine.mat"
    else
      initTransform="[$ref.nii.gz,${source}_4reg.nii.gz,2]"
    fi

    # set cost-functions
    metricMS="MeanSquares[$ref.nii.gz,${source}_4reg.nii.gz,1]"
    metricMI="MI[$ref.nii.gz,${source}_4reg.nii.gz,1,32]"
    metricCC="CC[$ref.nii.gz,${source}_4reg.nii.gz,1,3]"

    # reset the translation transformation for every slice
    if [[ $flgCheckReg -eq 1 ]] && [[ $(echo $similarityMetricOriginal $similarityMetricGood | awk '($1<$2){ print 1 }') -eq 1 ]] ; then
      # if the match with the reference is already good, use a more refined search
      transformTranslation=$(echo $transformLinear | sed 's/0\./0\.0/g')
      transformAffine=$(echo $transformLinear | sed 's/0\./0\.0/g')
    else
      transformTranslation=$transformLinear
      transformAffine=$transformLinear
    fi

    # register each slice by translation and scaling
    # when errors are detected, re-run with alternative initialisation
    flgRun=0
    maxRun=5
    while [[ $flgRun -le $maxRun ]]; do
      # initialise without any errors
      > $workDir/tmp/Error

      # register each slice by translation and scaling
      # order of 2D affine parameters: Xscale-Xshear-Yshear-Yscale-Xtrans-Ytrans
      antsRegistration \
        --dimensionality 2 \
        --output [${source}_] \
        --interpolation BSpline \
        --use-histogram-matching 1 \
        --winsorize-image-intensities [0.005,0.995] \
        $masks \
        --initial-moving-transform $initTransform \
        --transform Translation$transformTranslation \
        --metric $metricMS \
        --convergence $convergenceLinear \
        --shrink-factors $shrinkFactorsLinear \
        --smoothing-sigmas $smoothingSigmasLinear \
        --restrict-deformation 0x1 \
        --transform Affine$transformAffine \
        --metric $metricMS \
        --convergence $convergenceLinear \
        --shrink-factors $shrinkFactorsLinear \
        --smoothing-sigmas $smoothingSigmasLinear \
        --restrict-deformation 0x0x0x1x0x1 \
        --float \
        --verbose $flgVerbose 2> $workDir/tmp/Error

      [[ $flgVerbose -eq 1 ]] && echo "" && echo ""
      ((++flgRun))

      # check the quality of the registration, if requested
      if [[ $flgCheckReg -eq 1 ]] ; then
        # apply the linear transformation
        antsApplyTransforms \
          --dimensionality 2 \
          --input ${source}.nii.gz \
          --reference-image ${ref}.nii.gz \
          --output ${source}_checkLinear.nii.gz \
          --interpolation BSpline \
          --transform ${source}_0GenericAffine.mat \
          --default-value 0 \
          --float
        fslcpgeom $source ${source}_checkLinear

        # compare the result with the reference
        similarityMetricLinear=$(ImageMath 2 ${source}_out.nii.gz NormalizedCorrelation ${source}_checkLinear.nii.gz ${ref}.nii.gz $maskStrict.nii.gz)
        echo $v $s $similarityMetricLinear | awk '($3>-0.3){ print "Error, poor registration in volume " $1 ", slice " $2 ": " $3 }' > $workDir/tmp/Error
        echo $v $s $similarityMetricLinear $similarityMetricOriginal | awk '($3>$4){ print "Error, registration does not improve beyond the original source in volume " $1 ", slice " $2 ": " $3 " (linear fit) > " $4 " (original)" }' > $workDir/tmp/Error
      fi

      # check if an error was given
      if [[ -s $workDir/tmp/Error ]] ; then
        [[ $flgRun -eq 1 ]] && [[ $flgReportSlice -ne 1 ]] && echo "    slice $s" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1 && flgReportSlice=1

        # re-run, if the maximum number of runs has not yet been reached
        if [[ $flgRun -lt $maxRun ]] ; then
          if [[ $flgRun -eq 1 ]] ; then
            if [[ $flgCheckReg -eq 1 ]] && [[ $(echo $similarityMetricLinear | awk '($1>-0.3){ print 1 }') -eq 1 ]] ; then
              printf "      registration is poor, r-value: %.4f\n" $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            elif [[ $flgCheckReg -eq 1 ]] && [[ $(echo $similarityMetricLinear $similarityMetricOriginal | awk '($1>$2){ print 1 }') -eq 1 ]] ; then
              printf "      registration is okay, r-value: %.4f\n" $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
              printf "      but did not improve beyond the original match, r-value: %.4f\n" $similarityMetricOriginal >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            else
              printf "      registration is poor\n" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            fi
            echo "      trying again with new initialisation parameters" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          fi

          # update initalisation
          if [[ $initTransform =~ ,0]$ ]] ; then
            echo "      initialising based on the image intensities" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            initTransform=$(echo $initTransform | sed s/,0\]/,1\]/g)
          elif [[ $initTransform =~ ,1]$ ]] ; then
            if [[ $sPrev -ge 0 ]]; then
              echo "      initialising based on the previous slice (in acquisition order)" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
              sourcePrev=$volDir/${vol}_slice$(printf %04d $sPrev)
              initTransform="${sourcePrev}_0GenericAffine.mat"
            elif [[ $s -eq 1 ]]; then
              echo "      initialising based on slice 0 (ignoring acquisition order)" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
              # only for slice index 1 will we ignore the interleaved acquisition
              initTransform="$volDir/${vol}_slice0000_0GenericAffine.mat"
            elif [[ $v -gt 0 ]] ; then
              echo "      initialising based on slice 0 from the previous volume" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
              # only for slice index 0 will we use the previous volume
              sourcePrev=$(printf $workDir/vol%04d/vol%04d_$slice $((v-1)) $((v-1)))
              initTransform="${sourcePrev}_0GenericAffine.mat"
            else
              echo "      initialising based on the geometric origin of the images" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
              # how bad is your luck to have the registration fail on slice 0 of volume 0?
              initTransform=$(echo $initTransform | sed s/,1\]/,2\]/g)
            fi
          elif [[ $initTransform =~ ,2]$ ]] ; then
            echo "      initialising based on the geometric centre of the images" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            initTransform=$(echo $initTransform | sed s/,2\]/,0\]/g)
          else
            echo "      initialising based on the geometric origin of the images" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            initTransform="[$ref.nii.gz,${source}_4reg.nii.gz,2]"
          fi

        elif [[ $flgRun -eq $maxRun ]] ; then
          echo "      trying one last time with smaller registration steps" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          initTransform="[$ref.nii.gz,${source}_4reg.nii.gz,2]"
          transformTranslation=$(echo $transformTranslation | sed 's/0\./0\.0/g')
          transformAffine=$(echo $transformAffine | sed 's/0\./0\.0/g')

        else
          echo "      registration is consistently poor, running out of options..." >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          echo "      rather than estimating the registration," >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          printf "      let's simply " >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          flgKeepSource=0
          if [[ $sPrev -ge 0 ]]; then
            echo "copy the affine transform from the previous slice (in acquisition order)" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            sourcePrev=$volDir/${vol}_slice$(printf %04d $sPrev)
            cp ${sourcePrev}_0GenericAffine.mat ${source}_0GenericAffine.mat
          elif [[ $s -eq 1 ]]; then
            echo "copy the affine transform from slice 0 (ignoring acquisition order)" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            # only for slice index 1 will we ignore the interleaved acquisition
            cp $volDir/${vol}_slice0000_0GenericAffine.mat ${source}_0GenericAffine.mat
          elif [[ $v -gt 0 ]] ; then
            echo "copy the affine transform from slice 0 of the previous volume" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            # taking an affine transform from the previous volume
            sourcePrev=$(printf $workDir/vol%04d/vol%04d_$slice $((v-1)) $((v-1)))
            cp ${sourcePrev}_0GenericAffine.mat ${source}_0GenericAffine.mat
          else
            echo "keep the original slice as it is, without a transformation" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            flgKeepSource=1
          fi

          # checking whether copied affine transform is better than the original
          if [[ $flgCheckReg -eq 1 ]] && [[ $flgKeepSource -ne 1 ]] ; then
            # apply the linear transformation
            antsApplyTransforms \
              --dimensionality 2 \
              --input ${source}.nii.gz \
              --reference-image ${ref}.nii.gz \
              --output ${source}_checkLinear.nii.gz \
              --interpolation BSpline \
              --transform ${source}_0GenericAffine.mat \
              --default-value 0 \
              --float

            # compare the result with the reference and the original source
            similarityMetricLinear=$(ImageMath 2 ${source}_out.nii.gz NormalizedCorrelation ${source}_checkLinear.nii.gz ${ref}.nii.gz $maskStrict.nii.gz)
            if [[ $(echo $similarityMetricLinear $similarityMetricOriginal | awk '($1>-0.3||$1>$2){ print 1 }') -eq 1 ]] ; then
              flgKeepSource=1
              if [[ $flgCheckReg -eq 1 ]] && [[ $(echo $similarityMetricLinear | awk '($1>-0.3){ print 1 }') -eq 1 ]] ; then
                printf "      this registration is also poor, r-value: %.4f\n" $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
              else
                printf "      this registration is okay, r-value: %.4f\n" $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
                printf "      but did not improve beyond the original match, r-value: %.4f\n" $similarityMetricOriginal >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
              fi
              echo "      keeping the original slice as it is, without a transformation" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            else
              printf "      success, r-value: %.4f\n" $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
            fi
          fi

          # keep the original source without moving, if all has failed
          if [[ $flgKeepSource -eq 1 ]] ; then
            echo "#Insight Transform File V1.0" > $workDir/tmp/ident.txt
            echo "#Transform 0" >> $workDir/tmp/ident.txt
            echo "Transform: AffineTransform_double_2_2" >> $workDir/tmp/ident.txt
            echo "Parameters: 1 0 0 1 0 0" >> $workDir/tmp/ident.txt
            echo "FixedParameters: 0 0" >> $workDir/tmp/ident.txt
            ConvertTransformFile 2 $workDir/tmp/ident.txt ${source}_0GenericAffine.mat --convertToAffineType
            # copy the similarity metric from the original un-moved slice
            similarityMetricLinear=$similarityMetricOriginal
            # copy the original un-moved slice to the "check" output (just in case)
            imcp ${source} ${source}_checkLinear
          fi
          #cat $workDir/tmp/Error
        fi

      else

        # no error was given, so break the while loop
        if [[ $flgRun -gt 1 ]] ; then
          printf "      success" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          if [[ $flgCheckReg -eq 1 ]] ; then
            printf ", r-value: %.4f\n" $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          else
            printf "!\n" >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
          fi
        fi
        break

      fi

    done

    # check whether the linear registration is already good enough, and if so, skip the non-linear registration
    if [[ $flgCheckReg -eq 1 ]] && [[ $(echo $similarityMetricLinear $similarityMetricPerfect | awk '($1<$2){ print 1 }') -eq 1 ]] ; then
      [[ $flgReportSlice -ne 1 ]] && echo "    slice $s" && flgReportSlice=1
      printf "      linear registration is already good enough, r-value: %.4f\n" $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1

      # keep the linearly aligned slice as the final result
      imcp ${source}_checkLinear ${source}${sAligned}
      fslcpgeom $source ${source}${sAligned}

      # report
      printf "%.4f\t" $similarityMetricOriginal >> $reportFileOrig
      printf "%.4f\t" $similarityMetricLinear >> $reportFileLinear
      printf "%.4f\t" $similarityMetricLinear >> $reportFileWarp
      #printf "1\t" >> $reportFileNeighborhoodWarp

      # store warp
      if [[ $flgStoreWarp -eq 1 ]] ; then
        warpField=$transDir/warpField_${vol}_$slice.nii.gz
        displacementField=$transDir/displacementField_${vol}_$slice.nii.gz
        fslmaths $source -mul 0 $warpField
        # calculate the linear displacement field
        antsApplyTransforms \
          --dimensionality 2 \
          --input $source.nii.gz \
          --reference-image $ref.nii.gz \
          --output [$displacementField,1] \
          --interpolation BSpline \
          --transform [${source}_0GenericAffine.mat] \
          --default-value 0 \
          --float
        # keep only the y-component of the warp and displacement fields
        fslroi $displacementField $displacementField 1 1
        # copy geometry from source slice
        fslcpgeom $source $displacementField
      fi

      # continue to the next slice/volume
      continue

    fi


    # apply linear transformation
    antsApplyTransforms \
      --dimensionality 2 \
      --input $maskStrict.nii.gz \
      --reference-image ${source}.nii.gz \
      --output ${source}_mask.nii.gz \
      --interpolation NearestNeighbor \
      --transform [${source}_0GenericAffine.mat,1] \
      --default-value 0 \
      --float

    # fix the corrupted header after ANTs (reset slice thickness)
    fslcpgeom ${maskStrict} ${source}_mask

    # extract the head (additionally ignore the back of the skull and neck)
    if [[ $flgBias -eq 1 ]] && [[ $s -lt $idxSuperiorSlice ]] ; then
      fslmaths ${source}_restore -mas ${source}_mask ${source}_4reg
    else
      fslmaths $source -mas ${source}_mask ${source}_4reg
    fi

    # set masks to ignore voxels far out the relevant region (brain+head)
    if [[ $flgMaskZeros -eq 1 ]] ; then
      masks="--masks [$maskStrictDil.nii.gz,$maskStrictDil.nii.gz]"
    else
      masks=""
    fi

    # continue with non-linear registration
    antsRegistration \
      --dimensionality 2 \
      --output [${source}_] \
      --interpolation BSpline \
      --use-histogram-matching 1 \
      --winsorize-image-intensities [0.005,0.995] \
      $masks \
      --initial-moving-transform ${source}_0GenericAffine.mat \
      --transform BSplineSyN$transformNonLinear \
      --metric $metricCC \
      --convergence $convergenceNonLinear \
      --shrink-factors $shrinkFactorsNonLinear \
      --smoothing-sigmas $smoothingSigmasNonLinear \
      --restrict-deformation 0x1 \
      --verbose $flgVerbose \
      --float
    [[ $flgVerbose -eq 1 ]] && echo "" && echo ""

    # apply those deformation fields
    antsApplyTransforms \
      --dimensionality 2 \
      --input $source.nii.gz \
      --reference-image $ref.nii.gz \
      --output ${source}${sAligned}.nii.gz \
      --interpolation BSpline \
      --transform [${source}_1Warp.nii.gz] \
      --transform [${source}_0GenericAffine.mat] \
      --default-value 0 \
      --float

    fslcpgeom $source ${source}${sAligned}

    # calculate, compare, and report the registration similarity metrics
    if [[ $flgCheckReg -eq 1 ]] ; then
      [[ $flgVerbose -eq 1 ]] && [[ $flgReportSlice -ne 1 ]] && echo "    slice $s" && flgReportSlice=1

      # report the linear registration similarity metric
      printf "%.4f\t" $similarityMetricOriginal >> $reportFileOrig
      printf "%.4f\t" $similarityMetricLinear >> $reportFileLinear

      # calculate the non-linear registration similarity metric
      similarityMetricWarp=$(ImageMath 2 ${source}_out.nii.gz NormalizedCorrelation ${source}${sAligned}.nii.gz ${ref}.nii.gz $maskStrict.nii.gz)
      #similarityMetricNeighborhoodWarp=$(ImageMath 2 ${source}_out.nii.gz NeighborhoodCorrelation ${source}${sAligned}.nii.gz ${ref}.nii.gz 3 $maskStrict.nii.gz)
      #similarityMetricNeighborhoodLinear=$(ImageMath 2 ${source}_out.nii.gz NeighborhoodCorrelation ${source}_checkLinear.nii.gz ${ref}.nii.gz 3 $maskStrict.nii.gz)

      # compare the warp result against the linear registration
      if [[ $(echo $similarityMetricWarp $similarityMetricLinear | awk '($1>$2){ print 1 }') -eq 1 ]] ; then
        [[ $flgVerbose -eq 1 ]] && printf "      non-linear warp (%.4f) did not improve beyond linear registration (%.4f)\n" $similarityMetricWarp $similarityMetricLinear >> $reportFileProgress && [[ $flgVerbose -eq 1 ]] && cat $reportFileProgress | tail -n1
        # setting the warp field to zero displacement
        fslmaths ${source}_1Warp.nii.gz -mul 0 ${source}_1Warp.nii.gz
        # copying the linear result as the final aligned output
        imcp ${source}_checkLinear ${source}${sAligned}
        fslcpgeom $source ${source}${sAligned}
        # copy and re-calculate the similarity metrics
        similarityMetricWarp=$similarityMetricLinear
        #similarityMetricNeighborhoodWarp=$(ImageMath 2 ${source}_out.nii.gz NeighborhoodCorrelation ${source}${sAligned}.nii.gz ${ref}.nii.gz 3 $maskStrict.nii.gz)
      elif [[ $flgVerbose -eq 1 ]] ; then
        printf "      final non-linear registration similarity: %.4f\n" $similarityMetricWarp
      fi

      # report the similarity metrics
      printf "%.4f\t" $similarityMetricWarp >> $reportFileWarp
      #printf "%.4f\t" $similarityMetricNeighborhoodWarp >> $reportFileNeighborhoodWarp
    fi

    # store the affine transformation, if requested
    if [[ $flgStoreLinear -eq 1 ]] ; then
      ConvertTransformFile 2 ${source}_0GenericAffine.mat $workDir/tmp/yScaleTranslate.txt --homogeneousMatrix
      awk 'NR == 2 {printf "%.6f\t", $2; exit}' $workDir/tmp/yScaleTranslate.txt >> $reportFileYScale
      awk 'NR == 2 {printf "%.6f\t", $3; exit}' $workDir/tmp/yScaleTranslate.txt >> $reportFileYTranslate
    fi

    # store the non-linear warp transformation, if requested
    if [[ $flgStoreWarp -eq 1 ]] ; then
      warpField=$transDir/warpField_${vol}_$slice.nii.gz
      displacementField=$transDir/displacementField_${vol}_$slice.nii.gz

      # calculate the composite displacement field
      antsApplyTransforms \
        --dimensionality 2 \
        --input $source.nii.gz \
        --reference-image $ref.nii.gz \
        --output [$displacementField,1] \
        --interpolation BSpline \
        --transform [${source}_1Warp.nii.gz] \
        --transform [${source}_0GenericAffine.mat] \
        --default-value 0 \
        --float

      # keep only the y-component of the warp and displacement fields
      fslroi ${source}_1Warp $warpField 1 1
      fslroi $displacementField $displacementField 1 1

      # copy geometry from source slice
      fslcpgeom $source $warpField
      fslcpgeom $source $displacementField

    fi

  done

  # merge the slices
  volAligned=$workDir/${vol}${sAligned}
  fslmerge -z $volAligned $volDir/${vol}_slice*${sAligned}.nii.gz

  # copy geometry from reference image
  fslcpgeom $refImg $volAligned

  # clean-up intermediate files from the previous volume
  [[ $flgDebug -ne 1 ]] && [[ $v -gt 0 ]] && rm -rf $volDirPrevious

  # the current volume folder becomes the previous volume folder for the next iteration
  volDirPrevious=$volDir

  # merge and process the warp and displacement fields if requested
  if [[ $flgStoreWarp -eq 1 ]] ; then
    warpField=$transDir/warpField_${vol}.nii.gz
    displacementField=$transDir/displacementField_${vol}.nii.gz

    # merge the slices
    fslmerge -z $warpField $transDir/warpField_${vol}_slice*.nii.gz
    fslmerge -z $displacementField $transDir/displacementField_${vol}_slice*.nii.gz

    # copy geometry from reference image
    fslcpgeom $refImg $warpField
    fslcpgeom $refImg $displacementField

    # clean-up intermediate files
    if [[ $flgDebug -ne 1 ]] ; then
      find $transDir -type f -name "warpField_${vol}_slice*.nii.gz" -print0 | xargs -0 rm
      find $transDir -type f -name "displacementField_${vol}_slice*.nii.gz" -print0 | xargs -0 rm
    fi

  fi

  # start a new line in the similarity metric and transform reports
  if [[ $flgCheckReg -eq 1 ]] ; then
    printf "\n" >> $reportFileOrig
    printf "\n" >> $reportFileLinear
    printf "\n" >> $reportFileWarp
    #printf "\n" >> $reportFileNeighborhoodWarp
  fi
  [[ $flgStoreLinear -eq 1 ]] && printf "\n" >> $reportFileYScale && printf "\n" >> $reportFileYTranslate

done
[[ $flgVerbose -ne 1 ]] && printf "\n"

# ------------------------- #
# CREATE ALIGNED TIMESERIES
# ------------------------- #

# register all volumes to the reference
echo "" | tee -a $reportFileProgress
echo "CREATING ALIGNED EPI TIMESERIES AND MEAN IMAGE" | tee -a $reportFileProgress

# merge the volumes
echo "  merging image volumes into an image timeseries" | tee -a $reportFileProgress
if ((nVol > 999)); then
    fslmerge -t $workDir/${epi}${sAligned}_x1 $workDir/vol0*${sAligned}.nii.gz
    fslmerge -t $workDir/${epi}${sAligned}_x2 $workDir/vol1*${sAligned}.nii.gz
    if ((nVol > 1999)); then # If there are more than 2000 volumes, merge them as well
      fslmerge -t $workDir/${epi}${sAligned}_x3 $workDir/vol2*${sAligned}.nii.gz
      fslmerge -t $workDir/${epi}${sAligned}_x4 $workDir/vol3*${sAligned}.nii.gz
    fi
    fslmerge -t $epiDir/${epi}${sAligned} $workDir/${epi}${sAligned}_x*.nii.gz
else
    fslmerge -t $epiDir/${epi}${sAligned} $workDir/vol*${sAligned}.nii.gz
fi

# cut off spline interpolation ringing
thr=$(fslstats $epiDir/${epi}${sAligned} -R | awk '{print sqrt($1^2)/2}')
fslmaths $epiDir/${epi}${sAligned} -thr $thr $epiDir/${epi}${sAligned}

if [[ $flgStoreWarp -eq 1 ]] ; then
    # merge the warpfields and run PCA on displacement
    echo "  merging distortion fields into distortion timeseries" | tee -a $reportFileProgress

    if ((nVol > 999)); then
        fslmerge -t $transDir/motionWarpField_x1 $transDir/warpField_vol0*.nii.gz
        fslmerge -t $transDir/motionWarpField_x2 $transDir/warpField_vol1*.nii.gz
        if ((nVol > 1999)); then
            fslmerge -t $transDir/motionWarpField_x3 $transDir/warpField_vol2*.nii.gz
            fslmerge -t $transDir/motionWarpField_x4 $transDir/warpField_vol3*.nii.gz
        fi
        fslmerge -t $transDir/motionWarpField $transDir/motionWarpField_x*.nii.gz
    else
        fslmerge -t $transDir/motionWarpField $transDir/warpField_vol*.nii.gz
    fi

    if ((nVol > 999)); then
        fslmerge -t $transDir/motionDisplacementField_x1 $transDir/displacementField_vol0*.nii.gz
        fslmerge -t $transDir/motionDisplacementField_x2 $transDir/displacementField_vol1*.nii.gz
        if ((nVol > 1999)); then
          fslmerge -t $transDir/motionDisplacementField_x3 $transDir/displacementField_vol2*.nii.gz
          fslmerge -t $transDir/motionDisplacementField_x4 $transDir/displacementField_vol3*.nii.gz
        fi
        fslmerge -t $transDir/motionDisplacementField $transDir/motionDisplacementField_x*.nii.gz
    else
        fslmerge -t $transDir/motionDisplacementField $transDir/displacementField_vol*.nii.gz
    fi

    echo "  extracting principal components of distortions over time" | tee -a $reportFileProgress
    # determine number of components
    nComp=12 && [[ $nVol -le $nComp ]] && nComp=$((nVol-1))

    # calculate motion distance (absolute displacement)
    fslmaths $transDir/motionDisplacementField -abs $transDir/motionDistanceField

    # extract principal components
    ImageMath 4 $transDir/motionDisplacementComp.nii.gz CompCorrAuto $transDir/motionDisplacementField.nii.gz $refBrainMask.nii.gz $nComp
    ImageMath 4 $transDir/motionDistanceComp.nii.gz CompCorrAuto $transDir/motionDistanceField.nii.gz $refBrainMask.nii.gz $nComp

    # convert csv file to tab-delimited
    cat $transDir/motionDisplacementComp_compcorr.csv | tr "," "\t" > $transDir/motionDisplacementComp.txt
    cat $transDir/motionDistanceComp_compcorr.csv | tr "," "\t" > $transDir/motionDistanceComp.txt

    # clean-up intermediate files
    if [[ $flgDebug -ne 1 ]] ; then
      find $transDir -type f -name 'warpField_vol*.nii.gz' -print0 | xargs -0 rm
        find $transDir -type f -name 'displacementField_vol*.nii.gz' -print0 | xargs -0 rm
        find $transDir -type f -name 'motionWarpField_x*.nii.gz' -print0 | xargs -0 rm
        find $transDir -type f -name 'motionDisplacementField_x*.nii.gz' -print0 | xargs -0 rm
        rm $transDir/motionDistanceField.nii.gz $transDir/motionDisplacementComp_corrected.nii.gz $transDir/motionDistanceComp_corrected.nii.gz $transDir/motionDisplacementComp_compcorr.csv $transDir/motionDistanceComp_compcorr.csv
    fi
fi

# ------------------------- #
# CREATE ALIGNED TIMESERIES
# ------------------------- #

# check and report on the quality of the registration
sh /Users/carolineharbison/Desktop/Kentaro_data/Scripts/CheckMotionCorrection_3000vol.sh \
  --episeries=$epiDir/$epi \
  --refbrainmask=$refBrainMask \
  --workdir=$workDir \
  --suffixref=$sRef \
  --suffixaligned=$sAligned \
  --suffixbrainmask=$sBrainMask \
  --suffixdetrend=$sDetrend \
  --reportfile=$reportFileProgress \
  --debug=$flgDebug


# -------- #
# CLEAN-UP
# -------- #

# remove temporary files and images when not in debug mode

if [[ $flgDebug -ne 1 ]] && [[ $flgNewWorkDir -eq 1 ]] ; then
  rm -rf $workDir
fi

echo "" | tee -a $reportFileProgress
echo "DONE" | tee -a $reportFileProgress
#echo "  seconds elapsed: $SECONDS" | tee -a $reportFileProgress
echo "" | tee -a $reportFileProgress


<<"COMMENT"
# Hey, what are you doing here? You are not really supposed to read this. I just
# couldn't bare to throw this beautiful snippet of code away...

# find the widest point of the brain
fslmaths ${refBrainMask} -Xmean -mul $xSize ${refBrainMask}_width
brainWidth=$(fslstats ${refBrainMask}_width -P 95)
fslmaths ${refBrainMask}_width -thr $brainWidth -bin ${refBrainMask}_width

# find the width of the whole head at the same points
fslmaths ${refHeadMask} -Xmean -mul $xSize ${refHeadMask}_width
headWidth=$(fslstats ${refHeadMask}_width -k ${refBrainMask}_width -M)

# find the centre of the brain
#midSize=$(fslstats ${refBrainMask} -C | awk '{printf("%d\n",$1+=$0<0?-0.5:0.5)}') # in voxels
midSize=$(fslstats ${refBrainMask} -c | awk '{ print $1 }') # in mm

# widen the brain mask to match the width of the head
#xScale=$(echo $headWidth $brainWidth | awk '{print 1+(0.8*($1-$2)/$2)}')
xScale=$(echo $headWidth $brainWidth | awk '{print $1/$2}')

# find the translation to correct for the origin offset after scaling
xVoxSize=$(fslval ${refHeadMask} pixdim1)
xTranslate=$(echo $xVoxSize $midSize $xScale | awk '{ print $1+$2-($2*$3) }')

# write a transformation matrix
cat >$refDir/xscale.mat <<EOL
$xScale 0 0 $xTranslate
0 1 0 0
0 0 1 0
0 0 0 1
EOL

# rescale the brain mask along the x-axis
flirt -in ${refBrainMask} -ref ${refBrainMask} -applyxfm -init $refDir/xscale.mat -out ${refBrainMask}_xscale
fslmaths ${refBrainMask}_xscale -add ${refBrainMask} -bin ${refBrainMask}_xscale

# dilate the mask in the anterior direction to capture the sides and front of the head (including the eyes)
[[ $((ySize%2)) -eq 0 ]] && yKernelSize=$((ySize-1)) || yKernelSize=$ySize
fslroi $refImg ${refHeadMask}${sStrict} 0 1 0 $yKernelSize 0 1
fslmaths ${refHeadMask}${sStrict} -mul 0 -add 1 -roi 0 -1 0 $((1+$((yKernelSize-1))/2)) 0 -1 0 -1 ${refHeadMask}${sStrict}
fslmaths ${refBrainMask}_xscale -kernel file ${refHeadMask}${sStrict} -dilF ${refHeadMask}${sStrict}
COMMENT
