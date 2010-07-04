#!/bin/bash

# enable debugging
# set -x

# cmd line args
input_dir=$1    # ex: runnable
test_name=$2    # ex: pi

# env vars
# ARGS        == default set of dmd command line args to test combinatorially
# DMD         == compiler path and filename
# RESULTS_DIR == directory for temporary files and output

# enable support for expressions like *( ) in substitutions
shopt -s extglob

input_file=${input_dir}/${test_name}.d
output_dir=${RESULTS_DIR}/${input_dir}
output_file=${output_dir}/${test_name}.d.out
test_app=${output_dir}/${test_name}

rm -f ${output_file}

r_args=`grep REQUIRED_ARGS ${input_file} | tr -d \\\\r\\\\n`
if [ ! -z "${r_args}" ]; then
    r_args="${r_args/*REQUIRED_ARGS:*( )/}"
fi

p_args=`grep PERMUTE_ARGS ${input_file} | tr -d \\\\r\\\\n`
if [ -z "${p_args}" ]; then
    p_args="${ARGS}"
else
    p_args="${p_args/*PERMUTE_ARGS:*( )/}"
fi

e_args=`grep EXECUTE_ARGS  ${input_file} | tr -d \\\\r\\\\n`
if [ ! -z "$e_args" ]; then
    e_args="${e_args/*EXECUTE_ARGS:*( )/}"
fi

extra_sources=`grep EXTRA_SOURCES ${input_file} | tr -d \\\\r\\\\n`
if [ ! -z "${extra_sources}" ]; then
    extra_sources=(${extra_sources/*EXTRA_SOURCES:*( )/})
    extra_files="${extra_sources[*]/imports/${input_dir}/imports}"
fi

grep -q COMPILE_SEPARATELY ${input_file}
separate=$?

if [ "${input_dir}" != "runnable" ]; then
    extra_compile_args="-c"
fi

if [ "${input_dir}" != "fail_compilation" ]; then
    expect_compile_rc=0
else
    expect_compile_rc=1
fi


printf " ... %-30s required: %-5s permuted args: %s\n" "${input_file}" "${r_args}" "${p_args}"

${RESULTS_DIR}/combinations ${p_args} | while read x; do
    echo "dmd args: ${r_args} $x" >> ${output_file}

    if [ ${separate} -ne 0 ]; then
        ${DMD} -I${input_dir} ${r_args} $x -od${output_dir} -of${test_app} ${extra_compile_args} ${input_file} ${extra_files} >> ${output_file} 2>&1
        if [ $? -ne ${expect_compile_rc} ]; then
            cat ${output_file}
            rm -f ${output_file}
            exit 1
        fi
    else
        echo "separate compilation" >> ${output_file}
        for file in ${input_file} ${extra_files}; do
            ${DMD} -I${input_dir} ${r_args} $x -od${output_dir} -c $file >> ${output_file} 2>&1
            if [ $? -ne ${expect_compile_rc} ]; then
                cat ${output_file}
                rm -f ${output_file}
                exit 1
            fi
        done

        if [ "${input_dir}" = "runnable" ]; then
            ofiles=(${extra_sources[*]/imports\//})
            ofiles=(${ofiles[*]/%.d/.o})
            ofiles=(${ofiles[*]/#/${output_dir}\/})

            ${DMD} -od${output_dir} -of${test_app} ${test_app}.o ${ofiles[*]} >> ${output_file} 2>&1
            if [ $? -ne 0 ]; then
                cat ${output_file}
                rm -f ${output_file}
                exit 1
            fi
        fi
    fi

    if [ "${input_dir}" = "runnable" ]; then
        ${test_app} ${e_args} >> ${output_file} 2>&1
        if [ $? -ne 0 ]; then
            cat ${output_file}
            rm -f ${output_file}
            exit 1
        fi
    fi

    rm -f ${test_app} ${test_app}.o ${ofiles[*]}

    echo >> ${output_file}
done
