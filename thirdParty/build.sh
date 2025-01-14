#!/usr/bin/env bash

set -eo pipefail

cd $(dirname $0)
CWD=$(pwd)
TP_DIR=${CWD}

PARALLEL=$(getconf _NPROCESSORS_ONLN)
PACKAGE=""

function usage() {
    echo "Usage:"
    echo "    $0 [OPTIONS]..."
    echo ""
    echo "Options:"
    echo "    --j [parallel]"
    echo "        Specify the number of parallelism."
    echo "    --package [PACKAGE]"
    echo "        Specify the package, build all packages of is empty."
    echo "    --help"
    echo "        Show help message and exit."
    exit 1
}

while test $# -gt 0; do
    case $1 in
    --j)
        PARALLEL=$2
        shift 2
        ;;
    --package)
        PACKAGE=$2
        shift 2
        ;;
    --help)
        usage
        ;;
    *)
        echo Invalid parameters \"$@\".
        usage
        ;;
    esac
done

echo PARALLEL=$PARALLEL
echo PACKAGE=$PACKAGE

mkdir -p "${TP_DIR}/src"
mkdir -p "${TP_DIR}/installed/lib64"
pushd "${TP_DIR}/installed"/
ln -sf lib64 lib
popd

TP_SOURCE_DIR="${TP_DIR}/src"
TP_INSTALL_DIR="${TP_DIR}/installed"
TP_INCLUDE_DIR="${TP_INSTALL_DIR}/include"
TP_LIB_DIR="${TP_INSTALL_DIR}/lib"
TP_PATCH_DIR="${TP_DIR}/patches"


echo "SOURCE_DIR: ${TP_SOURCE_DIR}"
echo "INSTALL_DIR: ${TP_INSTALL_DIR}"
echo "INCLUDE_DIR: ${TP_INCLUDE_DIR}"
echo "LID_DIR: ${TP_LIB_DIR}"
echo "PATCH_DIR: ${TP_PATCH_DIR}"

# TODO: 检查编译工具和相关版本

function check_md5() {
    local FILE=$1
    local EXPECT=$2

    md5="$(md5 -q "${FILE}")"  # 使用macOS的md5命令
    if [[ "${md5}" != "${EXPECT}" ]]; then
        echo "${FILE} md5sum check failed!"
        echo -e "except-md5 ${EXPECT} \nactual-md5 ${md5}"
        exit 1
    else
        echo "${FILE} md5sum check passed!"
    fi
}

function build_openblas() {
    local URL="https://gh.llkk.cc/https://github.com/OpenMathLib/OpenBLAS/archive/refs/tags/v0.3.28.tar.gz"
    local FILE=OpenBLAS-0.3.28.tar.gz
    local DIR=OpenBLAS-0.3.28
    local MD5SUM="0f54185b6ef804173c01b9a40520a0e8"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || curl -L $URL -o ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    # 先编译 la_constants
    cd lapack-netlib/SRC
    gfortran -O2 -fPIC -c la_constants.f90
    cd ../..
    
    # 使用更简化的编译选项，完全禁用测试
    make clean
    make NO_SHARED=1 \
         DYNAMIC_ARCH=0 \
         USE_OPENMP=0 \
         NUM_THREADS=1 \
         TARGET=GENERIC \
         BINARY=64 \
         NO_LAPACKE=1 \
         NO_AFFINITY=1 \
         NO_AVX=1 \
         NO_PARALLEL_MAKE=1 \
         HOSTCC=clang \
         CC=clang \
         FC=gfortran \
         FFLAGS="-O2 -fPIC" \
         CFLAGS="-O2 -fPIC" \
         LDFLAGS="" \
         MAKE_NB_JOBS=1 \
         NO_TESTING=1 \
         NOFORTRAN=1 \
         libs

    make NO_SHARED=1 \
         DYNAMIC_ARCH=0 \
         USE_OPENMP=0 \
         NUM_THREADS=1 \
         TARGET=GENERIC \
         BINARY=64 \
         NO_LAPACKE=1 \
         NO_AFFINITY=1 \
         NO_AVX=1 \
         NO_PARALLEL_MAKE=1 \
         HOSTCC=clang \
         CC=clang \
         FC=gfortran \
         PREFIX=./build \
         MAKE_NB_JOBS=1 \
         NO_TESTING=1 \
         NOFORTRAN=1 \
         install

    mkdir -p ${TP_INCLUDE_DIR}/blas
    cp -r ./build/include/* ${TP_INCLUDE_DIR}/blas
    mkdir -p ${TP_LIB_DIR}
    cp -r ./build/lib/*.a ${TP_LIB_DIR}/
}

function build_faiss() {
    build_openblas

    local URL="https://gh.llkk.cc/https://github.com/facebookresearch/faiss/archive/refs/tags/v1.9.0.tar.gz"
    local FILE=faiss-1.9.0.tar.gz
    local DIR=faiss-1.9.0
    local MD5SUM="db62643ba325b296eeb84dc73897fe81"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    PATCHED_MARK="patched_mark"
    if [[ ! -f "${PATCHED_MARK}" ]]; then
        patch -p1 <"${TP_PATCH_DIR}/faiss-1.9.0.patch"
        touch "${PATCHED_MARK}"
    fi

    # 确保清理之前的构建
    rm -rf build

    # 使用更详细的 CMake 配置
    cmake -B build . \
        -DCMAKE_BUILD_TYPE=Release \
        -DFAISS_ENABLE_GPU=OFF \
        -DFAISS_ENABLE_PYTHON=OFF \
        -DBUILD_TESTING=OFF \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_INSTALL_PREFIX=$TP_INSTALL_DIR \
        -DTP_INSTALL_DIR=$TP_INSTALL_DIR \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DOpenMP_C_FLAGS="-Xpreprocessor -fopenmp" \
        -DOpenMP_CXX_FLAGS="-Xpreprocessor -fopenmp" \
        -DOpenMP_C_LIB_NAMES="omp" \
        -DOpenMP_CXX_LIB_NAMES="omp" \
        -DOpenMP_omp_LIBRARY="/opt/homebrew/opt/libomp/lib/libomp.dylib" \
        -DOpenMP_C_INCLUDE_DIR="/opt/homebrew/opt/libomp/include" \
        -DOpenMP_CXX_INCLUDE_DIR="/opt/homebrew/opt/libomp/include"

    make -C build -j ${PARALLEL} faiss install
}

function build_hnswlib() {
    local URL="https://gh.llkk.cc/https://github.com/nmslib/hnswlib/archive/refs/tags/v0.8.0.tar.gz"
    local FILE=hnswlib-0.8.0.tar.gz
    local DIR=hnswlib-0.8.0
    local MD5SUM="126c5c6b7d8e71c6e7c70dc4d5f3933e"

     [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    cp -r hnswlib ${TP_INCLUDE_DIR}/hnswlib

}

function build_rapidjson() {
    local REPO_URL="https://gh.llkk.cc/https://github.com/Tencent/rapidjson.git"
    local DIR=rapidjson

    # 检查是否已经 clone 仓库，如果没有则执行 clone
    if [ ! -d "${TP_SOURCE_DIR}/${DIR}" ]; then
        git clone ${REPO_URL} ${TP_SOURCE_DIR}/${DIR}
    fi

    cd ${TP_SOURCE_DIR}/${DIR}

    # 如果已经 clone，确保拉取最新的代码
    git fetch --all
    git pull origin $(git rev-parse --abbrev-ref HEAD)

    # 配置和安装
    cmake -B build . -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" \
                    -DRAPIDJSON_BUILD_DOC=OFF \
                    -DRAPIDJSON_BUILD_EXAMPLES=OFF \
                    -DRAPIDJSON_BUILD_TESTS=OFF
    make -C build install
}

function build_gtest() {
    local URL="https://gh.llkk.cc/https://github.com/google/googletest/releases/download/v1.15.2/googletest-1.15.2.tar.gz"
    local FILE=googletest-1.15.2.tar.gz
    local DIR=googletest-1.15.2
    local MD5SUM="7e11f6cfcf6498324ac82d567dcb891e"

    # 保存当前的环境变量
    local OLD_CFLAGS="$CFLAGS"
    local OLD_CXXFLAGS="$CXXFLAGS"
    local OLD_LDFLAGS="$LDFLAGS"

    # 清除可能影响构建的环境变量
    unset CFLAGS
    unset CXXFLAGS
    unset LDFLAGS

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    cmake -B build . -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" \
        -DCMAKE_C_FLAGS="-Wl,-no_pie" \
        -DCMAKE_CXX_FLAGS="-Wl,-no_pie"
    make -C build -j ${PARALLEL} install

    # 恢复环境变量
    export CFLAGS="$OLD_CFLAGS"
    export CXXFLAGS="$OLD_CXXFLAGS"
    export LDFLAGS="$OLD_LDFLAGS"
}

function build_backward() {
    local URL="https://gh.llkk.cc/https://github.com/bombela/backward-cpp/archive/refs/tags/v1.6.tar.gz"
    local FILE=v1.6.tar.gz
    local DIR=backward-cpp-1.6
    local MD5SUM="0facf6e0fb35ed0f3cd069424a1dc79a"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    cmake -B build . -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" 
    make -C build install
}

function build_httplib() {
    local URL="https://gh.llkk.cc/https://github.com/yhirose/cpp-httplib/archive/refs/tags/v0.18.1.tar.gz"
    local FILE=cpp-httplib-0.18.1.tar.gz
    local DIR=cpp-httplib-0.18.1
    local MD5SUM="a2427747a7c352fee8a1cc9e4db87168"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    mkdir -p ${TP_INCLUDE_DIR}/httplib
    cp ./httplib.h ${TP_INCLUDE_DIR}/httplib/
}

function build_spdlog() {
    local URL="https://gh.llkk.cc/https://github.com/gabime/spdlog/archive/refs/tags/v1.14.1.tar.gz"
    local FILE=spdlog-1.14.1.tar.gz
    local DIR=spdlog-1.14.1
    local MD5SUM="f2c3f15c20e67b261836ff7bfda302cf"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    cmake -B build . -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}"
    make -C build -j ${PARALLEL} install
}

function build_gflags() {
    local URL="https://gh.llkk.cc/https://github.com/gflags/gflags/archive/refs/tags/v2.2.1.tar.gz"
    local FILE=gflags-2.2.1.tar.gz
    local DIR=gflags-2.2.1
    local MD5SUM="b98e772b4490c84fc5a87681973f75d1"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    
    # 确保清理并创建构建目录
    rm -rf build
    mkdir -p build
    chmod 755 build  # 确保目录有正确的权限

    cmake -B build . \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX=$TP_INSTALL_DIR \
          -DBUILD_SHARED_LIBS=OFF \
          -DBUILD_TESTING=OFF \
          -DBUILD_STATIC_LIBS=ON \
          -DREGISTER_INSTALL_PREFIX=OFF

    make -C build -j ${PARALLEL} install
}

function build_glog() {
    local URL="https://gh.llkk.cc/https://github.com/google/glog/archive/refs/tags/v0.6.0.tar.gz"
    local FILE=glog-0.6.0.tar.gz
    local DIR=glog-0.6.0
    local MD5SUM="c98a6068bc9b8ad9cebaca625ca73aa2"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    cmake -S . -B build -G "Unix Makefiles" -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" \
                                            -DCMAKE_BUILD_TYPE=Release \
                                            -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
                                            -DWITH_UNWIND=OFF \
                                            -DBUILD_SHARED_LIBS=OFF \
                                            -DWITH_TLS=OFF
    cmake --build build -j ${PARALLEL} --target install
}

function build_zlib() {
    local URL="https://gh.llkk.cc/https://github.com/madler/zlib/archive/refs/tags/v1.2.13.tar.gz"
    local FILE=zlib-1.2.13.tar.gz
    local DIR=zlib-1.2.13
    local MD5SUM="9c7d356c5acaa563555490676ca14d23"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    rm -rf build
    mkdir -p build
    CFLAGS="-O3 -fPIC" \
    CPPFLAGS="-I${TP_INCLUDE_DIR}" \
    LDFLAGS="-L${TP_LIB_DIR}" \
    ./configure --prefix="${TP_SOURCE_DIR}/${DIR}/build"
    make -j ${PARALLEL} install
    cp -r ./build/include/* ${TP_INCLUDE_DIR}/
    cp -r ./build/lib/*.a ${TP_LIB_DIR}/
}

function build_protobuf() {
    local URL="https://gh.llkk.cc/https://github.com/protocolbuffers/protobuf/archive/refs/tags/v3.17.3.tar.gz"
    local FILE=protobuf-3.17.3.tar.gz
    local DIR=protobuf-3.17.3
    local MD5SUM="d7f8e0e3ffeac721e18cdf898eff7d31"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    mkdir -p cmake/build
    cd cmake/build
    CXXFLAGS="-I${TP_INCLUDE_DIR}" \
    cmake -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -Dprotobuf_BUILD_SHARED_LIBS=OFF \
        -Dprotobuf_BUILD_TESTS=OFF \
        -DZLIB_LIBRARY="${TP_LIB_DIR}/libz.a" \
        -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" ../
    make -j ${PARALLEL} install
    parse_proto
}

function parse_proto(){
    PROTO_FOLDER=${TP_DIR}/proto

    # 确保 proto 目录存在
    mkdir -p ${PROTO_FOLDER}

    # 检查目录是否为空
    if [ -z "$(ls -A ${PROTO_FOLDER}/*.proto 2>/dev/null)" ]; then
        echo "Warning: No .proto files found in ${PROTO_FOLDER}"
        return 0  # 如果没有 proto 文件，直接返回
    fi

    # 清理旧的生成文件
    rm -f ${PROTO_FOLDER}/*.pb.h
    rm -f ${PROTO_FOLDER}/*.pb.cc

    # 确保 protoc 可执行
    chmod +x ${TP_INSTALL_DIR}/bin/protoc

    # 编译所有 proto 文件
    for proto_file in ${PROTO_FOLDER}/*.proto; do
        if [ -f "$proto_file" ]; then
            echo "Processing proto file: $proto_file"
            ${TP_INSTALL_DIR}/bin/protoc --cpp_out=$PROTO_FOLDER -I $PROTO_FOLDER $proto_file
        fi
    done

    echo "Proto processing finished"
}

function build_leveldb() {
    local URL="https://gh.llkk.cc/https://github.com/google/leveldb/archive/refs/tags/1.23.tar.gz"
    local FILE=leveldb-1.23.tar.gz
    local DIR=leveldb-1.23
    local MD5SUM="afbde776fb8760312009963f09a586c7"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}

    CXXFLAGS="-fPIC" cmake -B build . -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" -DLEVELDB_BUILD_BENCHMARKS=OFF \
        -DLEVELDB_BUILD_TESTS=OFF
    make -C build -j ${PARALLEL} install
}

function build_openssl() {
    local URL="https://gh.llkk.cc/https://github.com/openssl/openssl/archive/refs/tags/OpenSSL_1_1_1.tar.gz"
    local FILE=openssl-OpenSSL_1_1_1.tar.gz
    local DIR=openssl-OpenSSL_1_1_1
    local MD5SUM="d65944e4aa4de6ad9858e02c82d85183"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}

    # 清理之前的构建
    make clean || true
    rm -rf build
    
    # 设置环境变量
    export KERNEL_BITS=64
    export MACOSX_DEPLOYMENT_TARGET=11.0

    # 使用 ./config 进行自动配置
    ./config --prefix="${TP_INSTALL_DIR}" \
            --openssldir="${TP_INSTALL_DIR}" \
            no-shared \
            no-tests \
            no-unit-test \
            no-asm \
            no-threads \
            no-dso \
            no-hw \
            -fPIC

    # 设置正确的编译器标志
    sed -i '' 's/-arch i386//g' Makefile
    sed -i '' 's/-arch x86_64//g' Makefile

    # 只构建库文件
    make -j ${PARALLEL} build_libs
    make install_sw

    # 清理不需要的文件
    rm -rf ${TP_INSTALL_DIR}/bin/openssl
    rm -rf ${TP_INSTALL_DIR}/ssl
    rm -rf ${TP_INSTALL_DIR}/lib/*.so*
    rm -rf ${TP_INSTALL_DIR}/lib/*.dylib
    rm -rf ${TP_INSTALL_DIR}/lib/pkgconfig
    rm -rf ${TP_INSTALL_DIR}/share
}

function build_brpc() {
    local URL="https://gh.llkk.cc/https://github.com/apache/brpc/archive/refs/tags/1.11.0.tar.gz"
    local FILE=brpc-1.11.0.tar.gz
    local DIR=brpc-1.11.0
    local MD5SUM="f55e582fb8032768f9070865b48e892d"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    PATCHED_MARK="patched_mark"
    if [[ ! -f "${PATCHED_MARK}" ]]; then
        patch -p1 <"${TP_PATCH_DIR}/brpc-1.11.0.patch"
        touch "${PATCHED_MARK}"
    fi
    sed '/set(OPENSSL_ROOT_DIR/,/)/ d' ./CMakeLists.txt >./CMakeLists.txt.bak
    mv ./CMakeLists.txt.bak ./CMakeLists.txt

    cmake -B build . \
        -DBUILD_SHARED_LIBS=ON \
        -DWITH_GLOG=ON \
        -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" \
        -DCMAKE_LIBRARY_PATH="${TP_INSTALL_DIR}/lib64" \
        -DCMAKE_INCLUDE_PATH="${TP_INSTALL_DIR}/include" \
        -DBUILD_BRPC_TOOLS=OFF \
        -DWITH_SNAPPY=ON \
        -DPROTOBUF_PROTOC_EXECUTABLE="${TP_INSTALL_DIR}/bin/protoc" \
        -DSNAPPY_INCLUDE_PATH="${TP_INCLUDE_DIR}/snappy" \
        -DSNAPPY_LIB="${TP_LIB_DIR}/libsnappy.a" \
        -DCMAKE_PREFIX_PATH="${TP_INSTALL_DIR}"

    make -C build -j ${PARALLEL} install
    if [[ -f "${TP_INSTALL_DIR}/lib/libbrpc.so" ]]; then
        rm -rf "${TP_INSTALL_DIR}"/lib/libbrpc.so*
    fi
}
        

function build_snappy() {
    local URL="https://gh.llkk.cc/https://github.com/google/snappy/archive/refs/tags/1.2.1.tar.gz"
    local FILE=snappy-1.2.1.tar.gz
    local DIR=snappy-1.2.1
    local MD5SUM="dd6f9b667e69491e1dbf7419bdf68823"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}

    cmake -B build . -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" \
            -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
            -DCMAKE_INSTALL_INCLUDEDIR="${TP_INCLUDE_DIR}"/snappy \
            -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF

    make -C build -j ${PARALLEL} install
}

function build_lz4() {
    local URL="https://gh.llkk.cc/https://github.com/lz4/lz4/archive/refs/tags/v1.9.4.tar.gz"
    local FILE=lz4-1.9.4.tar.gz
    local DIR=lz4-1.9.4
    local MD5SUM="e9286adb64040071c5e23498bf753261"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    make -j ${PARALLEL} install PREFIX="${TP_INSTALL_DIR}" BUILD_SHARED=no INCLUDEDIR="${TP_INCLUDE_DIR}/lz4"
}

function build_bzip() {
    local URL="https://fossies.org/linux/misc/bzip2-1.0.8.tar.gz"
    local FILE=bzip2-1.0.8.tar.gz
    local DIR=bzip2-1.0.8
    local MD5SUM="67e051268d0c475ea773822f7500d0e5"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    make -j ${PARALLEL} install PREFIX="${TP_INSTALL_DIR}"
}

function build_rocksdb() {
    local URL="https://gh.llkk.cc/https://github.com/facebook/rocksdb/archive/refs/tags/v8.0.0.tar.gz"
    local FILE=rocksdb-8.0.0.tar.gz
    local DIR=rocksdb-8.0.0
    local MD5SUM="148458e1efd16cc235a0ddb2796313f0"

    [ -f ${TP_SOURCE_DIR}/${FILE} ] || wget $URL -O ${TP_SOURCE_DIR}/${FILE}
    check_md5 ${TP_SOURCE_DIR}/${FILE} $MD5SUM
    [ -d ${TP_SOURCE_DIR}/${DIR} ] || tar xvf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR}

    cd ${TP_SOURCE_DIR}/${DIR}
    
    # 设置编译环境变量
    export CFLAGS="-I${TP_INCLUDE_DIR} -I${TP_INCLUDE_DIR}/snappy -I${TP_INCLUDE_DIR}/lz4 -Wno-error=unused-but-set-variable"
    export CXXFLAGS="${CFLAGS}"
    export LDFLAGS="-static-libstdc++ -static-libgcc"
    export PORTABLE=1
    
    # 清理之前的构建
    make clean || true
    
    # 构建静态库
    make USE_RTTI=1 \
         DISABLE_WARNING_AS_ERROR=1 \
         -j ${PARALLEL} \
         static_lib
    
    # 安装文件
    cp librocksdb.a ${TP_LIB_DIR}/librocksdb.a
    cp -r include/rocksdb ${TP_INCLUDE_DIR}/
}

function build_roaringbitmap() {
    local URL="https://gh.llkk.cc/https://github.com/RoaringBitmap/CRoaring/archive/refs/tags/v2.1.2.tar.gz"
    local FILE=CRoaring-2.1.2.tar.gz
    local DIR=CRoaring-2.1.2

    # 清理可能存在的旧文件
    rm -f ${TP_SOURCE_DIR}/${FILE}
    rm -rf ${TP_SOURCE_DIR}/${DIR}

    # 保存当前的环境变量
    local OLD_CFLAGS="$CFLAGS"
    local OLD_CXXFLAGS="$CXXFLAGS"
    local OLD_LDFLAGS="$LDFLAGS"

    # 清除可能影响构建的环境变量
    unset CFLAGS
    unset CXXFLAGS
    unset LDFLAGS

    # 下载文件
    wget $URL -O ${TP_SOURCE_DIR}/${FILE} || {
        echo "Failed to download CRoaring"
        return 1
    }

    # 解压文件
    tar xf ${TP_SOURCE_DIR}/${FILE} -C ${TP_SOURCE_DIR} || {
        echo "Failed to extract CRoaring"
        rm -f ${TP_SOURCE_DIR}/${FILE}
        return 1
    }

    cd ${TP_SOURCE_DIR}/${DIR} || {
        echo "Failed to change directory to ${TP_SOURCE_DIR}/${DIR}"
        return 1
    }

    # 构建
    cmake -B build . \
        -DROARING_BUILD_STATIC=ON \
        -DCMAKE_INSTALL_PREFIX="${TP_INSTALL_DIR}" \
        -DENABLE_ROARING_TESTS=OFF \
        -DROARING_BUILD_BENCHMARKS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON || {
        echo "CMake configuration failed"
        # 恢复环境变量
        export CFLAGS="$OLD_CFLAGS"
        export CXXFLAGS="$OLD_CXXFLAGS"
        export LDFLAGS="$OLD_LDFLAGS"
        return 1
    }

    make -C build -j ${PARALLEL} install || {
        echo "Make failed"
        # 恢复环境变量
        export CFLAGS="$OLD_CFLAGS"
        export CXXFLAGS="$OLD_CXXFLAGS"
        export LDFLAGS="$OLD_LDFLAGS"
        return 1
    }

    # 恢复环境变量
    export CFLAGS="$OLD_CFLAGS"
    export CXXFLAGS="$OLD_CXXFLAGS"
    export LDFLAGS="$OLD_LDFLAGS"

    echo "RoaringBitmap built successfully"
}

PACKAGES=(
    "faiss"
    "hnswlib"
    "rapidjson"
    "httplib"
    "spdlog"
    "gflags"
    "glog"
    "zlib"
    "protobuf"
    "leveldb"
    "openssl"
    "snappy"
    "brpc"
    "lz4"
    "bzip"
    "rocksdb"
    "roaringbitmap"
    "gtest"
    "backward"
)

function build() {
    local package=$1
    if [[ -z "$package" ]]; then
        for pkg in "${PACKAGES[@]}"; do
            build_"$pkg"
        done
    else
        if [[ " ${PACKAGES[*]} " == *" $package "* ]]; then
            build_"$package"
        else
            echo "Package $package not found."
        fi
    fi
    echo "build finish!"
}

build $PACKAGE

