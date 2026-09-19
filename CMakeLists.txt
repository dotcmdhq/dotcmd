cmake_minimum_required(VERSION 3.24)
if(CMAKE_HOST_APPLE)
    # An explicit SDK keeps /usr/local Homebrew headers out of compiler defaults.
    set(CMAKE_OSX_SYSROOT "macosx" CACHE STRING "macOS SDK")
    set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS version")
endif()
project(dotcmd LANGUAGES C CXX)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "Build configuration" FORCE)
endif()
set(DOTCMD_VERSION "dev" CACHE STRING "dotcmd release version")
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
include(ExternalProject)

# Build pinned library sources locally. All downloads require TLS and SHA-256.
set(deps "${CMAKE_BINARY_DIR}/deps")
set(prefix "${CMAKE_STATIC_LIBRARY_PREFIX}")
set(suffix "${CMAKE_STATIC_LIBRARY_SUFFIX}")
set(dependency_args
    -DCMAKE_BUILD_TYPE=MinSizeRel
    -DBUILD_SHARED_LIBS=OFF
    "-DCMAKE_INSTALL_PREFIX:PATH=${deps}/install"
    -DCMAKE_INSTALL_LIBDIR=lib
    "-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY:PATH=${deps}/lib"
    "-DCMAKE_ARCHIVE_OUTPUT_DIRECTORY_MINSIZEREL:PATH=${deps}/lib")
if(MSVC)
    list(APPEND dependency_args -DCMAKE_C_FLAGS=/Gy -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded)
else()
    list(APPEND dependency_args "-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections")
endif()
# External projects must use the same compiler, SDK, and generator tools.
foreach(variable CMAKE_C_COMPILER CMAKE_C_COMPILER_ARG1
        CMAKE_RC_COMPILER CMAKE_MAKE_PROGRAM CMAKE_TOOLCHAIN_FILE DOTCMD_ZIG DOTCMD_ZIG_TARGET
        CMAKE_OSX_SYSROOT CMAKE_OSX_DEPLOYMENT_TARGET)
    if(DEFINED ${variable})
        string(REPLACE ";" "|" value "${${variable}}")
        list(APPEND dependency_args "-D${variable}:STRING=${value}")
    endif()
endforeach()

function(add_dependency name url hash)
    cmake_parse_arguments(DEP "INSTALL" "" "OPTIONS;TARGETS;DEPENDS;BYPRODUCTS" ${ARGN})
    set(build "${CMAKE_COMMAND}" --build <BINARY_DIR> --config MinSizeRel --parallel 4)
    if(DEP_TARGETS)
        list(APPEND build --target ${DEP_TARGETS})
    endif()
    set(install "")
    if(DEP_INSTALL)
        set(install "${CMAKE_COMMAND}" --install <BINARY_DIR> --config MinSizeRel)
    endif()
    ExternalProject_Add(dep_${name}
        PREFIX "${deps}/${name}-ep"
        SOURCE_DIR "${deps}/${name}-src"
        BINARY_DIR "${deps}/${name}"
        DOWNLOAD_DIR "${deps}/downloads"
        URL "${url}" URL_HASH "SHA256=${hash}" TLS_VERIFY ON
        LIST_SEPARATOR "|"
        CMAKE_ARGS ${dependency_args} ${DEP_OPTIONS}
        BUILD_COMMAND ${build}
        INSTALL_COMMAND "${install}"
        BUILD_BYPRODUCTS ${DEP_BYPRODUCTS}
        DEPENDS ${DEP_DEPENDS}
        USES_TERMINAL_BUILD TRUE)
endfunction()

# Lua has no CMake project; compile its library sources here.
set(lua_sources)
foreach(name lapi lauxlib lbaselib lcode lcorolib lctype ldblib ldebug ldo ldump lfunc lgc
        linit liolib llex lmathlib lmem loadlib lobject lopcodes loslib lparser lstate
        lstring lstrlib ltable ltablib ltm lundump lutf8lib lvm lzio)
    list(APPEND lua_sources "${deps}/lua-src/src/${name}.c")
endforeach()
ExternalProject_Add(dep_lua
    PREFIX "${deps}/lua-ep" SOURCE_DIR "${deps}/lua-src"
    DOWNLOAD_DIR "${deps}/downloads"
    URL "https://www.lua.org/ftp/lua-5.5.1.tar.gz"
    URL_HASH "SHA256=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce" TLS_VERIFY ON
    CONFIGURE_COMMAND "" BUILD_COMMAND "" INSTALL_COMMAND ""
    BUILD_BYPRODUCTS ${lua_sources})
set_source_files_properties(${lua_sources} PROPERTIES GENERATED TRUE)
add_library(lua STATIC ${lua_sources})
add_dependencies(lua dep_lua)
target_include_directories(lua PUBLIC "${deps}/lua-src/src")
set_target_properties(lua PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED YES)
if(UNIX)
    target_compile_definitions(lua PRIVATE LUA_USE_POSIX)
endif()

# HTTPS: Schannel on Windows, LibreSSL on Unix, and system trust on macOS.
set(curl_library "${deps}/lib/libcurl${suffix}")
set(http_options
    -DBUILD_TESTING=OFF
    -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_EXAMPLES=OFF
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF
    -DCURL_DISABLE_INSTALL=ON -DHTTP_ONLY=ON -DCURL_USE_PKGCONFIG=OFF
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON -DCURL_DISABLE_OPENSSL_AUTO_LOAD_CONFIG=ON
    -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF
    -DUSE_LIBIDN2=OFF -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF)
set(http_dependencies)
set(tls_libraries)
if(WIN32)
    list(APPEND http_options -DCURL_USE_SCHANNEL=ON -DCURL_USE_OPENSSL=OFF)
else()
    set(ssl_library "${deps}/lib/${prefix}ssl${suffix}")
    set(crypto_library "${deps}/lib/${prefix}crypto${suffix}")
    add_dependency(libressl
        "https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-4.3.2.tar.gz"
        "edf01aee24c65d69e6a9efcb9d44bcda682ff9d4f3bbbd95e794e1dfa90847b5"
        TARGETS ssl crypto BYPRODUCTS "${ssl_library}" "${crypto_library}"
        OPTIONS -DLIBRESSL_APPS=OFF -DLIBRESSL_TESTS=OFF -DLIBRESSL_SKIP_INSTALL=ON -DOPENSSLDIR=/etc/ssl)
    list(APPEND http_dependencies dep_libressl)
    list(APPEND tls_libraries "${ssl_library}" "${crypto_library}")
    list(APPEND http_options -DCURL_USE_OPENSSL=ON -DOPENSSL_USE_STATIC_LIBS=ON
        "-DOPENSSL_INCLUDE_DIR:PATH=${deps}/libressl-src/include"
        "-DOPENSSL_SSL_LIBRARY:FILEPATH=${ssl_library}"
        "-DOPENSSL_CRYPTO_LIBRARY:FILEPATH=${crypto_library}")
    if(APPLE)
        list(APPEND http_options -DUSE_APPLE_SECTRUST=ON -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none)
    endif()
endif()
add_dependency(curl
    "https://github.com/curl/curl/releases/download/curl-8_22_0/curl-8.22.0.tar.xz"
    "f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7"
    TARGETS libcurl_static BYPRODUCTS "${curl_library}"
    DEPENDS ${http_dependencies} OPTIONS ${http_options})

# Archive readers with gzip/xz, without optional libraries or command-line tools.
set(zlib_name z)
if(WIN32)
    set(zlib_name zs)
endif()
set(zlib_library "${deps}/lib/${prefix}${zlib_name}${suffix}")
set(lzma_library "${deps}/lib/${prefix}lzma${suffix}")
set(archive_library "${deps}/lib/${prefix}archive${suffix}")
add_dependency(zlib
    "https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.gz"
    "bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16"
    INSTALL BYPRODUCTS "${zlib_library}"
    OPTIONS -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF)
add_dependency(xz
    "https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz"
    "0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9"
    INSTALL TARGETS liblzma BYPRODUCTS "${lzma_library}"
    OPTIONS -DBUILD_TESTING=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF
        -DXZ_DOC=OFF -DXZ_NLS=OFF -DXZ_TOOL_SCRIPTS=OFF)
set(archive_options -DENABLE_ZLIB=ON -DENABLE_LZMA=ON -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON
    -DPOSIX_REGEX_LIB=NONE
    "-DZLIB_INCLUDE_DIR:PATH=${deps}/install/include" "-DZLIB_LIBRARY:FILEPATH=${zlib_library}"
    "-DLIBLZMA_INCLUDE_DIR:PATH=${deps}/install/include" "-DLIBLZMA_LIBRARY:FILEPATH=${lzma_library}")
foreach(feature MBEDTLS NETTLE OPENSSL LIBB2 LZ4 LZO ZSTD BZip2 LIBXML2 EXPAT WIN32_XMLLITE
        PCREPOSIX PCRE2POSIX LIBGCC CNG TAR CPIO CAT UNZIP XATTR ACL ICONV TEST INSTALL)
    list(APPEND archive_options "-DENABLE_${feature}=OFF")
endforeach()
add_dependency(archive
    "https://github.com/libarchive/libarchive/releases/download/v3.8.9/libarchive-3.8.9.tar.gz"
    "f5a6539059cf5e597dbeda37bfa4874b1e8dea063c8d93bf85a2b44af90a5bd4"
    TARGETS archive_static BYPRODUCTS "${archive_library}"
    DEPENDS dep_zlib dep_xz OPTIONS ${archive_options})

# Embed resources at configure time; unchanged headers keep their timestamps.
set(generated "${CMAKE_BINARY_DIR}/generated")
function(embed path symbol)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${path}")
    file(READ "${path}" bytes HEX)
    string(REGEX REPLACE "(................................)" "\\1\n" bytes "${bytes}")
    string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," bytes "${bytes}")
    file(CONFIGURE OUTPUT "${generated}/${symbol}.h"
        CONTENT "static const unsigned char ${symbol}[] = {\n${bytes}\n};\n" @ONLY)
endfunction()
embed("${CMAKE_CURRENT_SOURCE_DIR}/src/main.lua" main_lua)
embed("${CMAKE_CURRENT_SOURCE_DIR}/THIRD_PARTY.txt" licenses)
file(GENERATE OUTPUT "${generated}/$<CONFIG>/build_config.h" CONTENT
    "#define DOTCMD_VERSION \"${DOTCMD_VERSION}\"\n#define DOTCMD_BUILD \"$<IF:$<CONFIG:Debug>,debug,release>\"\n#define DOTCMD_COMPILER \"${CMAKE_CXX_COMPILER_ID} ${CMAKE_CXX_COMPILER_VERSION}\"\n")

# Compile the host and link static dependencies.
# The host uses C++ syntax but no C++ standard library or runtime.
set(CMAKE_CXX_IMPLICIT_LINK_LIBRARIES "")
add_executable(dotcmd src/main.cpp src/http.cpp src/exec.cpp src/sha256.cpp src/fs.cpp src/extract.cpp)
add_dependencies(dotcmd dep_curl dep_archive)
set_target_properties(dotcmd PROPERTIES CXX_STANDARD 11 CXX_STANDARD_REQUIRED YES CXX_EXTENSIONS NO LINKER_LANGUAGE C)
target_include_directories(dotcmd PRIVATE "${generated}/$<CONFIG>" "${generated}"
    "${deps}/curl-src/include" "${deps}/archive-src/libarchive")
target_compile_definitions(dotcmd PRIVATE CURL_STATICLIB LIBARCHIVE_STATIC)
target_link_libraries(dotcmd PRIVATE lua "${curl_library}" ${tls_libraries}
    "${archive_library}" "${lzma_library}" "${zlib_library}")
if(MSVC)
    target_compile_options(dotcmd PRIVATE /W4 /WX /GR- /EHs-c-)
    target_link_options(dotcmd PRIVATE /OPT:REF)
else()
    target_compile_options(lua PRIVATE -ffunction-sections -fdata-sections)
    target_compile_options(dotcmd PRIVATE -Wall -Wextra -Werror -fno-exceptions -fno-rtti
        -ffunction-sections -fdata-sections)
    if(APPLE)
        target_link_options(dotcmd PRIVATE -Wl,-dead_strip "$<$<NOT:$<CONFIG:Debug>>:-Wl,-x>")
    else()
        target_link_options(dotcmd PRIVATE -static -Wl,--gc-sections "$<$<NOT:$<CONFIG:Debug>>:-s>")
    endif()
endif()
if(WIN32)
    enable_language(RC)
    target_sources(dotcmd PRIVATE src/windows.rc)
    target_include_directories(dotcmd PRIVATE src)
    target_link_libraries(dotcmd PRIVATE ws2_32 crypt32 secur32 bcrypt advapi32 iphlpapi)
    if(MINGW)
        target_link_options(dotcmd PRIVATE -municode)
    endif()
else()
    target_include_directories(dotcmd PRIVATE "${deps}/libressl-src/include")
    target_link_libraries(dotcmd PRIVATE m)
    if(APPLE)
        target_link_libraries(dotcmd PRIVATE "-framework Security" "-framework CoreFoundation"
            "-framework CoreServices" "-framework SystemConfiguration")
    endif()
endif()

# Run the existing public .cmd tests with this build's executable.
set(CMAKE_CTEST_ARGUMENTS --verbose)
enable_testing()
configure_file(.cmd .cmd COPYONLY)
file(CONFIGURE OUTPUT "${CMAKE_BINARY_DIR}/.cmd.lua" CONTENT
    "return {test = assert(loadfile([==[${CMAKE_CURRENT_SOURCE_DIR}/test/run.lua]==]))()}\n" @ONLY)
add_test(NAME dotcmd COMMAND dotcmd --launcher "${CMAKE_BINARY_DIR}/.cmd" test "${CMAKE_CURRENT_SOURCE_DIR}")
set_tests_properties(dotcmd PROPERTIES WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}")
