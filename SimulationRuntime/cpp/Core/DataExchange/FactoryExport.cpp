//#pragma once

#if defined(__vxworks)
    
  

#elif defined(OMC_BUILD)
#include "stdafx.h"
#include <DataExchange/SimData.h>

/* OMC factory*/
using boost::extensions::factory;

BOOST_EXTENSION_TYPE_MAP_FUNCTION {
  types.get<std::map<std::string, factory<ISimData > > >()
    ["SimData"].set<SimData>();
}
#elif defined(SIMSTER_BUILD)
#include "stdafx.h"
#include <DataExchange/SimData.h>

/*Simster factory*/
 extern "C" void BOOST_EXTENSION_EXPORT_DECL extension_export_dataExchange(boost::extensions::factory_map & fm)
{
     fm.get<ISimData,int>()[1].set<SimData>();
}
#else
    error "operating system not supported"
#endif


