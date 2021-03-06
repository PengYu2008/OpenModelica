find_package(CURL REQUIRED)
find_package(Intl REQUIRED)
find_package(Iconv REQUIRED)

if(OMC_USE_LAPACK)
  find_package(LAPACK REQUIRED)

  # Check if our lapack version have the deprecated functions.
  set(CMAKE_REQUIRED_LIBRARIES_OLD ${CMAKE_REQUIRED_LIBRARIES})
  set(CMAKE_REQUIRED_LIBRARIES ${LAPACK_LIBRARIES})
  check_function_exists(dgeqpf_ OMC_HAVE_LAPACK_DEPRECATED)
  set(CMAKE_REQUIRED_LIBRARIES ${CMAKE_REQUIRED_LIBRARIES_OLD})
endif()


# find_package(ZLIB REQUIRED) # Not needed. We use the minizip lib from 3rdParty/FMIL instead

# On Win32 we use system UUID lib which is one of the default libs that cmake adds to any target on Win32. On non Win32
# systems we need to link explicitly to uuid. However, there is no FindUUID yet. We can add one later. Instead we use
# find library for now. It should be okay for now since I am guessing uuid headers should be in the default include dirs
# anyway.
if(NOT WIN32)
  find_library(UUID_LIB NAMES uuid REQUIRED)
endif()


# Existence checks
#################################################################################################

# Some example portability checks. Add more just like this if you need more.
# e.g this will define HAVE_TIME_H 1 if found or HAVE_TIME_H 0 otherwise
omc_check_header_exists_and_define(time.h)
# e.g this will define HAVE_CTIME_S 1 if found or HAVE_CTIME_S 0 otherwise
omc_check_function_exists_and_define(ctime_s)
omc_check_function_exists_and_define(ctime_r)



# Libraries
##################################################################################################
set(OMC_RUNTIIME_SOURCES
    Error_omc.cpp
    Dynload_omc.cpp
    Print_omc.c
    ErrorMessage.cpp
    System_omc
    Lapack_omc.cpp
    Settings_omc.cpp
    UnitParserExt_omc.cpp
    unitparser.cpp
    IOStreamExt_omc.cpp
    Socket_omc.c
    ZeroMQ_omc.c
    getMemorySize.c
    OMSimulator_omc.c
    is_utf8.c
    om_curl.c
    om_unzip.c
    ptolemyio_omc.cpp
    SimulationResults_omc.c
    systemimplmisc.cpp)


# ######################################################################################################################
# Library: omcruntime
add_library(omcruntime STATIC)
add_library(omc::compiler::runtime ALIAS omcruntime)

target_sources(omcruntime PRIVATE ${OMC_RUNTIIME_SOURCES})
target_compile_features(omcruntime PRIVATE cxx_std_11)

target_link_libraries(omcruntime PUBLIC CURL::libcurl)
target_link_libraries(omcruntime PUBLIC ${Intl_LIBRARIES})
target_link_libraries(omcruntime PUBLIC Iconv::Iconv)
target_link_libraries(omcruntime PUBLIC omc::simrt::runtime)
target_link_libraries(omcruntime PUBLIC omc::3rd::libzmq)
target_link_libraries(omcruntime PUBLIC omc::3rd::FMIL::minizip) # We use the minizip lib from 3rdParty/FMIL

if(OMC_USE_LPSOLVE)
  target_link_libraries(omcruntime PUBLIC omc::3rd::lpsolve55)
else()
  target_compile_definitions(omcruntime PRIVATE NO_LPLIB)
endif()

if(OMC_USE_LAPACK)
  target_link_libraries(omcruntime PUBLIC ${LAPACK_LIBRARIES})
endif()

target_include_directories(omcruntime PUBLIC ${Intl_INCLUDE_DIRS})
target_include_directories(omcruntime PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_include_directories(omcruntime PRIVATE ${OMCompiler_SOURCE_DIR}) # for revision.h

# uuid is one of the default libs that cmake adds to any target on Win32. On non-Win systems we look for the library and
# explicitly use it.
if(NOT WIN32)
  target_link_libraries(omcruntime PUBLIC ${UUID_LIB})
endif()

# Corba support
if(OMC_USE_CORBA)
  if(MINGW)
    # setup omniORB for MinGW OMDev
    include(.cmake/omdev_omniorb_setup.cmake)
    # Include the macro for compiling corba targets.
    include(.cmake/omc_omniorb_corba_target.cmake)

    # Make a directory specifically for generated files
    set(GENERATED_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/generated)
    file(MAKE_DIRECTORY ${GENERATED_DIRECTORY})

    # add a corba target for omc_communication.idl. The outputs will be put in the generated files directory.
    omc_add_omniorb_corba_target(${OMNIIDL_EXE} ${CMAKE_CURRENT_SOURCE_DIR}/omc_communication.idl
                                 ${GENERATED_DIRECTORY})
    # Add the generated files to the sources of the library
    target_sources(omcruntime PRIVATE ${GENERATED_DIRECTORY}/omc_communication.cc omc_communication_impl.cpp
                                      Corba_omc.cpp)

    target_link_libraries(omcruntime PUBLIC omdev::omniORB::omniORB420_rt)
    target_link_libraries(omcruntime PUBLIC omdev::omniORB::omnithread40_rt)
    target_compile_definitions(omcruntime PRIVATE USE_CORBA)
    target_include_directories(omcruntime PRIVATE ${GENERATED_DIRECTORY})
  else() # Not MinGW
    message(FATAL "Corba support for non-MinGW omc builds is not yet implemented.")
  endif()
else() # No corba support requested. Use the stub file.
  target_sources(omcruntime PRIVATE corbaimpl_stub_omc.c)
endif(OMC_USE_CORBA)


# ######################################################################################################################
# Library: omcbackendruntime
add_library(omcbackendruntime STATIC)
add_library(omc::compiler::backendruntime ALIAS omcbackendruntime)

set(OMC_BACKENDRUNTIIME_SOURCES
    HpcOmSchedulerExt_omc.cpp
    HpcOmBenchmarkExt_omc.cpp
    TaskGraphResults_omc.cpp
    BackendDAEEXT_omc.cpp
    matching.c
    matching_cheap.c
    FMI_omc.c
    cJSON.c)

target_sources(omcbackendruntime PRIVATE ${OMC_BACKENDRUNTIIME_SOURCES})

target_link_libraries(omcbackendruntime PUBLIC ${Intl_LIBRARIES})
target_link_libraries(omcbackendruntime PUBLIC omc::simrt::runtime)
target_link_libraries(omcbackendruntime PUBLIC omc::3rd::fmilib::static)
target_link_libraries(omcbackendruntime PUBLIC omc::3rd::metis)

target_include_directories(omcbackendruntime PUBLIC ${Intl_INCLUDE_DIRS})
target_include_directories(omcbackendruntime PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_include_directories(omcbackendruntime PRIVATE ${OMCompiler_SOURCE_DIR}) # for revision.h

# ######################################################################################################################
# Library: omcgraphstream
add_library(omcgraphstream STATIC)
add_library(omc::compiler::graphstream ALIAS omcgraphstream)

set(OMC_GRAPH_STREAM_SOURCES GraphStreamExt_omc.cpp)
target_sources(omcgraphstream PRIVATE ${OMC_GRAPH_STREAM_SOURCES})

target_link_libraries(omcgraphstream PUBLIC omc::simrt::runtime)
target_link_libraries(omcgraphstream PUBLIC omc::3rd::netstream)

# Remove the dependency of bootstrapping on graphstream lib and remove this. It is not needed for bootstrapping.
# ######################################################################################################################
# Library: omcgraphstream-boot
add_library(omcgraphstream-boot STATIC)
add_library(omc::compiler::graphstream-boot ALIAS omcgraphstream-boot)

set(OMC_GRAPH_STREAM_SOURCES GraphStreamExt_omc.cpp)
target_sources(omcgraphstream-boot PRIVATE ${OMC_GRAPH_STREAM_SOURCES})

# Define OMC_BOOTSTRAPPING for the boot lib.
target_compile_definitions(omcgraphstream-boot PRIVATE OMC_BOOTSTRAPPING)

target_link_libraries(omcgraphstream-boot PUBLIC omc::simrt::runtime)
target_link_libraries(omcgraphstream-boot PUBLIC omc::3rd::netstream)










################################################################################
# This is a lazy approach to generating runtime/config.unix.h and Compiler/Util/Autoconf.mo
# Needs to be refactored quite a bit. The variable names should be updated to be more
# unique and descriptive. 
# However, If I do that I need to update the .in files which means the normal compilation is
# also affected. As a result I would have to change a few things since many things depend on
# the generated output files. For now just mimic the old compilation.


set(SHREXT ${CMAKE_SHARED_LIBRARY_SUFFIX})
string(TOLOWER ${CMAKE_SYSTEM_NAME} OMC_TARGET_SYSTEM_NAME)
omc_add_to_report(OMC_TARGET_SYSTEM_NAME)
set(OPENMODELICA_SPEC_PLATFORM ${CMAKE_SYSTEM_PROCESSOR}-${OMC_TARGET_SYSTEM_NAME})

if(${CMAKE_SIZEOF_VOID_P} EQUAL 8)
  set(OMC_TARGET_ARCH_IS_64 TRUE)
  set(MODELICA_SPEC_PLATFORM "${OMC_TARGET_SYSTEM_NAME}64")
else()
  set(OMC_TARGET_ARCH_IS_64 FALSE)
  set(MODELICA_SPEC_PLATFORM "${OMC_TARGET_SYSTEM_NAME}32")
endif()

set(host_short ${CMAKE_SYSTEM_PROCESSOR}-${OMC_TARGET_SYSTEM_NAME})

set(RUNTIMECC ${CMAKE_C_COMPILER})
set(CC ${CMAKE_C_COMPILER})
set(CXX ${CMAKE_CXX_COMPILER})

find_package(OpenMP)
if(OpenMP_FOUND)
  set(OMPCFLAGS "-fopenmp")
endif()

set(LPSOLVEINC "lpsolve/lp_lib.h")

if(LAPACK_FOUND)
  set(HAVE_LAPACK "#define HAVE_LAPACK")
  if(OMC_HAVE_LAPACK_DEPRECATED)
    set(HAVE_LAPACK_DEPRECATED "#define HAVE_LAPACK_DEPRECATED")
  endif()
endif()

# set(prefix ${CMAKE_INSTALL_PREFIX})
set(prefix "")

find_package(Git)
execute_process(COMMAND
  ${GIT_EXECUTABLE} describe --match "v*.*" --always
  WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
  OUTPUT_VARIABLE SOURCE_REVISION
  ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE
)

if(OpenMP_FOUND)
  set(CONFIG_WITH_OPENMP 1)
else()
  set(CONFIG_WITH_OPENMP 0)
endif()

set(WITH_UMFPACK "#define WITH_UMFPACK")
set(WITH_HWLOC 0)
set(WITH_UUID "#define WITH_LIBUUID 1")


set(USE_GRAPH 0)

configure_file(${CMAKE_CURRENT_SOURCE_DIR}/revision.h.in ${CMAKE_CURRENT_SOURCE_DIR}/revision.h)
configure_file(${CMAKE_CURRENT_SOURCE_DIR}/config.unix.h.in ${CMAKE_CURRENT_SOURCE_DIR}/config.unix.h)


# Generate Autoconf.mo here since we have some of the variables already defined for config.unix.h above. 

if(WIN32)

  if(OMC_TARGET_ARCH_IS_64)
    set(ISMINGW64 "true")
  else()
    set(ISMINGW64 "false")
  endif()

  if(${CMAKE_CXX_COMPILER_VERSION} STREQUAL "5.3.0")
    set(IS_NEW_OMDEV "false")
  else()
    set(IS_NEW_OMDEV "true")
  endif()

  configure_file(${CMAKE_CURRENT_SOURCE_DIR}/../Util/Autoconf.mo.omdev.mingw ${CMAKE_CURRENT_SOURCE_DIR}/../Util/Autoconf.mo)

else()
  check_c_compiler_flag("-Wl,-Bstatic  -Wl,-Bdynamic" BSTATIC_INT)
  if(BSTATIC_INT)
    set(BSTATIC "true")
  else()
    set(BSTATIC "false")
  endif()

  set(CONFIG_OS ${OMC_TARGET_SYSTEM_NAME})
  set(MAKE ${CMAKE_MAKE_PROGRAM})
 
  configure_file(${CMAKE_CURRENT_SOURCE_DIR}/../Util/Autoconf.mo.in ${CMAKE_CURRENT_SOURCE_DIR}/../Util/Autoconf.mo)
endif()
