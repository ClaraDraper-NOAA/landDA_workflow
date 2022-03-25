#!/bin/bash

# script to perform snow depth update for UFS. Includes: 
# 1. staging and preparation of obs. 
#    note: IMS obs prep currently requires model background, then conversion to IODA format
# 2. creation of pseudo ensemble 
# 3. run LETKF to generate increment file 
# 4. add increment file to restarts (=disaggregation of bulk snow depth update into updates 
#    to SWE snd SD in each snow layer).

# Clara Draper, Oct 2021.

# to-do: 
# check that slmsk is always taken from the forecast file (oro files has a different definition)
# make sure documentation is updated.

File_setting=$1
############################
# read in DA settings for the experiment
while read line
do
    [[ -z "$line" ]] && continue
    [[ $line =~ ^#.* ]] && continue
    key=$(echo ${line} | cut -d'=' -f 1)
    value=$(echo ${line} | cut -d'=' -f 2)
    case ${key} in
        "CYCLEDIR")
        CYCLEDIR=${value}
        ;;
        "EXPDIR")
        EXPDIR=${value}
        ;;
        "exp_name")
        exp_name=${value}
        ;;
        "ensemble_size")
        ensemble_size=${value}
        ;;
        "do_DA")
        do_DA=${value}
        ;;
        "ASSIM_IMS")
        ASSIM_IMS=${value}
        ;;
        "ASSIM_GHCN")
        ASSIM_GHCN=${value}
        ;;
        "ASSIM_SYNTH")
        ASSIM_SYNTH=${value}
        ;;
        "WORKDIR")
        WORKDIR=${value}
        ;;
        "DIFF_CYCLEDIR")
        DIFF_CYCLEDIR=${value}
        ;;
        "OBSDIR")
        OBSDIR=${value}
        ;;
        "JEDI_EXECDIR")
        JEDI_EXECDIR=${value}
        ;;
        "IODA_BUILD_DIR")
        IODA_BUILD_DIR=${value}
        ;;
        #default case
        #*)
        #echo ${line}
        #;;
    esac
done < "$File_setting"

# user directories
if [[ -z "$CYCLEDIR" ]]; then
    CYCLEDIR=$(pwd)  # this directory
fi
if [[ ! -z "$DIFF_CYCLEDIR" ]]; then
    CYCLEDIR=${DIFF_CYCLEDIR}  # overwrite if DIFF_CYCLEDIR is set
fi
if [[ -z "$EXPDIR" ]]; then
    EXPDIR=$(pwd)  # this directory
fi

SCRIPTDIR=${CYCLEDIR}/landDA_workflow/
OUTDIR=${EXPDIR}/${exp_name}/output/
LOGDIR=${OUTDIR}/DA/logs/
RSTRDIR=$WORKDIR/restarts/tile # is running offline cycling will be here

# create the jedi yaml name 

# construct yaml name
if [ $do_DA == "hofx" ]; then
     JEDI_YAML=${DAtype}"_offline_hofx"
else
     JEDI_YAML=${DAtype}"_offline_DA"
fi

if [ $ASSIM_IMS == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_IMS" ; fi
if [ $ASSIM_GHCN == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_GHCN" ; fi
if [ $ASSIM_SYNTH == "YES" ]; then JEDI_YAML=${JEDI_YAML}"_SYNTH"; fi

JEDI_YAML=${JEDI_YAML}"_C96.yaml" # IMS and GHCN

echo "JEDI YAML is: "$JEDI_YAML

if [[ ! -e ${DADIR}/jedi/fv3-jedi/yaml_files/$JEDI_YAML ]]; then
     echo "YAML does not exist, exiting"
     exit
fi

# executable directories

FIMS_EXECDIR=${SCRIPTDIR}/IMSobsproc/exec/   
INCR_EXECDIR=${SCRIPTDIR}/AddJediIncr/exec/   

# JEDI FV3 Bundle directories

JEDI_STATICDIR=${SCRIPTDIR}/jedi/fv3-jedi/Data/

# EXPERIMENT SETTINGS

RES=${RES:-96}
NPROC_DA=${NPROC_DA:-6} 
B=30  # back ground error std.

# STORAGE SETTINGS 

SAVE_IMS="YES" # "YES" to save processed IMS IODA file
SAVE_INCR="YES" # "YES" to save increment (add others?) JEDI output
SAVE_TILE="NO" # "YES" to save background in tile space

THISDATE=${THISDATE:-"2015090118"}

############################################################################################
if [[ $JEDI_YAML == *"letkfoi"* ]]; then  
    ens_list=(mem_pos mem_neg)
else
    if [ $ensemble_size -gt 1 ]; then
        declare -a ens_list=( $(for (( i=1; i<=${ensemble_size}; i++ )); do echo 0; done) ) # empty array
        ensemble_count=0
        for i in ${ens_list[@]}
        do
            ens_list[ensemble_count]="mem_`printf %02i $((ensemble_count + 1))`"
            ensemble_count=$((ensemble_count+1))
        done
    fi
fi

############################################################################################
# SHOULD NOT HAVE TO CHANGE ANYTHING BELOW HERE

echo 'THISDATE in land DA, '$THISDATE

cd $WORKDIR 

source ${SCRIPTDIR}/workflow_mods_bash
module list 

################################################
# FORMAT DATE STRINGS
################################################

INCDATE=${SCRIPTDIR}/incdate.sh

# substringing to get yr, mon, day, hr info
YYYY=`echo $THISDATE | cut -c1-4`
MM=`echo $THISDATE | cut -c5-6`
DD=`echo $THISDATE | cut -c7-8`
HH=`echo $THISDATE | cut -c9-10`

PREVDATE=`${INCDATE} $THISDATE -6`

YYYP=`echo $PREVDATE | cut -c1-4`
MP=`echo $PREVDATE | cut -c5-6`
DP=`echo $PREVDATE | cut -c7-8`
HP=`echo $PREVDATE | cut -c9-10`

FILEDATE=${YYYY}${MM}${DD}.${HH}0000

DOY=$(date -d "${YYYY}-${MM}-${DD}" +%j)

if [[ ! -e ${WORKDIR}/output ]]; then
ln -s ${OUTDIR} ${WORKDIR}/output
fi 

if  [[ $SAVE_TILE == "YES" ]]; then
    for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
    do
        if [[ $JEDI_YAML == *"letkf_"* ]]; then  
            ens_member=${ens_list[$ensemble_count]}
            ENSEMBLE_DIR=${WORKDIR}/${ens_member}
            restart_back_id=.${ens_member}_back
        else
            ENSEMBLE_DIR=${WORKDIR}
            restart_back_id='_back'
        fi
        RSTRDIR=$ENSEMBLE_DIR/restarts/tile
        for tile in 1 2 3 4 5 6
        do
            source_restart=${RSTRDIR}/${FILEDATE}.sfc_data.tile${tile}.nc
            target_restart=${OUTDIR}/restarts/${FILEDATE}.sfc_data${restart_back_id}.tile${tile}.nc
            cp ${source_restart} ${target_restart}
        done
    done
fi

#stage restarts for applying JEDI update (files will get directly updated)
for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
do
    if [[ $JEDI_YAML == *"letkf_"* ]]; then  
        ens_member=${ens_list[$ensemble_count]}
        ENSEMBLE_DIR=${WORKDIR}/${ens_member}
    else
        ENSEMBLE_DIR=${WORKDIR}
    fi
    RSTRDIR=$ENSEMBLE_DIR/restarts/tile
    for tile in 1 2 3 4 5 6
    do
        source_restart=${RSTRDIR}/${FILEDATE}.sfc_data.tile${tile}.nc
        target_restart=${ENSEMBLE_DIR}/${FILEDATE}.sfc_data.tile${tile}.nc
        echo "Trace 05 restart file in "${SCRIPT}": "${target_restart}" is linked from "${source_restart}
        $ln -s ${source_restart} ${target_restart}
    done
    $ln -s ${RSTRDIR}/${FILEDATE}.coupler.res ${ENSEMBLE_DIR}/${FILEDATE}.coupler.res
done

################################################
# PREPARE OBS FILES
################################################

# SET IODA PYTHON PATHS
export PYTHONPATH="${IODA_BUILD_DIR}/lib/pyiodaconv":"${IODA_BUILD_DIR}/lib/python3.6/pyioda"

# use a different version of python for ioda converter (keep for create_ensemble, as latter needs netCDF4)
echo "BEFORE"
echo $PATH 
PATH_BACKUP=$PATH
module load intelpython/3.6.8 
echo "AFTER" 
echo $PATH
export PATH=$PATH:${PATH_BACKUP}
echo "FIXED" 
echo $PATH

# stage GHCN
if [[ $ASSIM_GHCN == "YES" ]]; then
ln  -s $OBSDIR/GHCN/data_proc/ghcn_snwd_ioda_${YYYY}${MM}${DD}.nc  ghcn_${YYYY}${MM}${DD}.nc
fi 

# stage synthetic obs.
if [[ $ASSIM_SYNTH == "YES" ]]; then
ln -s $OBSDIR/synthetic_noahmp/IODA.synthetic_gswp_obs.${YYYY}${MM}${DD}18.nc  synth_${YYYY}${MM}${DD}.nc
fi 

# prepare IMS

if [[ $ASSIM_IMS == "YES" ]]; then

cat >> fims.nml << EOF
 &fIMS_nml
  idim=$RES, jdim=$RES,
  jdate=${YYYY}${DOY},
  yyyymmdd=${YYYY}${MM}${DD},
  IMS_OBS_PATH="${OBSDIR}/IMS/data_in/${YYYY}/",
  IMS_IND_PATH="${OBSDIR}/IMS/index_files/"
  /
EOF

    echo 'snowDA: calling fIMS'

    ${FIMS_EXECDIR}/calcfIMS
    if [[ $? != 0 ]]; then
        echo "fIMS failed"
        exit 10
    fi

    cp ${SCRIPTDIR}/jedi/ioda/imsfv3_scf2ioda.py $WORKDIR

    echo 'snowDA: calling ioda converter' 

    python imsfv3_scf2ioda.py -i IMSscf.${YYYY}${MM}${DD}.C${RES}.nc -o ${WORKDIR}ioda.IMSscf.${YYYY}${MM}${DD}.C${RES}.nc 
    if [[ $? != 0 ]]; then
        echo "IMS IODA converter failed"
        exit 10
    fi

fi

################################################
# CREATE PSEUDO-ENSEMBLE
################################################

for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
do
    if [[ $JEDI_YAML == *"letkf_"* ]]; then  
        ens_member=${ens_list[$ensemble_count]}
        ENSEMBLE_DIR=${WORKDIR}/${ens_member}
    else
        ENSEMBLE_DIR=${WORKDIR}
    fi
    RSTRDIR=$ENSEMBLE_DIR/restarts/tile

    cp -r ${RSTRDIR} $ENSEMBLE_DIR
done

echo 'snowDA: calling create ensemble' 

if [[ $JEDI_YAML == *"letkfoi_"* ]]; then  
    python ${SCRIPTDIR}/letkf_create_ens.py $FILEDATE $B
else
fi
if [[ $? != 0 ]]; then
    echo "letkf create failed"
    exit 10
fi

################################################
# RUN LETKF
################################################

# switch back to orional python for fv3-jedi
module load intelpython/2021.3.0

# prepare namelist
cp ${SCRIPTDIR}/jedi/fv3-jedi/yaml_files/$JEDI_YAML ${WORKDIR}/letkf_snow.yaml
if [[ $JEDI_YAML == *"letkf_"* ]]; then  
    key_word="USER_ENSEMBLE_MEMBER"
    for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
    do
        ens_numbers=$((ensemble_count+1))
        ens_member=${ens_list[$ensemble_count]}
        target_word="- datetime: XXYYYY-XXMM-XXDDTXXHH:00:00Z\n"
        target_word=${target_word}"     filetype: fms restart\n"
        target_word=${target_word}"     state variables: [snwdph,vtype,slmsk]\n"
        target_word=${target_word}"     datapath: ${ens_member}\/\n"
        target_word=${target_word}"     filename_sfcd: XXYYYYXXMMXXDD.XXHH0000.sfc_data.nc\n"
        if [ $ens_numbers -lt $ensemble_size ]; then
          target_word=${target_word}"     filename_cplr: XXYYYYXXMMXXDD.XXHH0000.coupler.res\n"
          target_word=${target_word}"   ${key_word}"
        else
          target_word=${target_word}"     filename_cplr: XXYYYYXXMMXXDD.XXHH0000.coupler.res"
        fi
        sed -i -e "s/${key_word}/${target_word}/g" letkf_snow.yaml
    done
fi

sed -i -e "s/XXYYYY/${YYYY}/g" letkf_snow.yaml
sed -i -e "s/XXMM/${MM}/g" letkf_snow.yaml
sed -i -e "s/XXDD/${DD}/g" letkf_snow.yaml
sed -i -e "s/XXHH/${HH}/g" letkf_snow.yaml

sed -i -e "s/XXYYYP/${YYYP}/g" letkf_snow.yaml
sed -i -e "s/XXMP/${MP}/g" letkf_snow.yaml
sed -i -e "s/XXDP/${DP}/g" letkf_snow.yaml
sed -i -e "s/XXHP/${HP}/g" letkf_snow.yaml

ln -s $JEDI_STATICDIR Data 

echo 'snowDA: calling fv3-jedi' 

# C48 and C96
if [[ $do_DA == "hofx" ]]; then  # h(x) only
srun -n $NPROC_DA ${JEDI_EXECDIR}/fv3jedi_hofx_nomodel.x letkf_snow.yaml ${LOGDIR}/jedi_letkf.log
else
srun -n $NPROC_DA ${JEDI_EXECDIR}/fv3jedi_letkf.x letkf_snow.yaml ${LOGDIR}/jedi_letkf.log
fi 

################################################
# APPLY INCREMENT TO UFS RESTARTS 
################################################

if [[ $do_DA == "LETKF-OI" || $do_DA == "LETKF" ]]; then  # do DA

cat << EOF > apply_incr_nml
&noahmp_snow
 date_str=${YYYY}${MM}${DD}
 hour_str=$HH
 res=$RES
/
EOF

echo 'snowDA: calling apply increment'

# (n=6) -> this is fixed, at one task per tile (with minor code change, could run on a single proc). 
srun '--export=ALL' -n 6 ${INCR_EXECDIR}/apply_incr ${LOGDIR}/apply_incr.log
echo $?

fi 

################################################
# CLEAN UP
################################################

if  [[ $SAVE_TILE == "YES" ]]; then
    for (( ensemble_count=0; ensemble_count<ensemble_size; ensemble_count++ ))
    do
        if [[ $JEDI_YAML == *"letkf_"* ]]; then  
            ens_member=${ens_list[$ensemble_count]}
            ENSEMBLE_DIR=${WORKDIR}/${ens_member}
            restart_anal_id=.${ens_member}_anal
        else
            ENSEMBLE_DIR=${WORKDIR}
            restart_anal_id='_anal'
        fi
        RSTRDIR=$ENSEMBLE_DIR/restarts/tile
        for tile in 1 2 3 4 5 6
        do
            target_restart=${OUTDIR}/restarts/${FILEDATE}.sfc_data${restart_anal_id}.tile${tile}.nc
            source_restart=${RSTRDIR}/${FILEDATE}.sfc_data.tile${tile}.nc
            cp ${source_restart} ${target_restart}
        done
    done
fi

# keep IMS IODA file
if [ $SAVE_IMS == "YES"  ] && [ $ASSIM_IMS == "YES"  ]; then
        cp ${WORKDIR}ioda.IMSscf.${YYYY}${MM}${DD}.C${RES}.nc ${OUTDIR}/DA/IMSproc/
fi 

# keep increments
if [ $SAVE_INCR == "YES" ] && [[ $do_DA == "LETKF-OI" || $do_DA == "LETKF" ]]; then
        cp ${WORKDIR}/${FILEDATE}.xainc.sfc_data.tile*.nc  ${OUTDIR}/DA/jedi_incr/
fi 
