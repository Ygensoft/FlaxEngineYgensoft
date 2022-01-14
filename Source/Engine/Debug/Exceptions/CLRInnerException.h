// Copyright (c) 2012-2022 Wojciech Figat. All rights reserved.

#pragma once

#include "Engine/Debug/Exception.h"

namespace Log
{
    /// <summary>
    /// The exception that is thrown when a method call is invalid in an object's current state.
    /// </summary>
    class CLRInnerException : public Exception
    {
    public:

        /// <summary>
        /// Init
        /// </summary>
        CLRInnerException()
            : CLRInnerException(String::Empty)
        {
        }

        /// <summary>
        /// Creates default exception with additional data
        /// </summary>
        /// <param name="message">Additional information that help describe error</param>
        CLRInnerException(const String& additionalInfo)
            : Exception(String::Format(TEXT("Current {0} CLR method has thrown an inner exception"),
#if USE_MONO
                                       TEXT("Mono")
#elif USE_CORECLR
				TEXT(".NET Core")
#else
				TEXT("Unknown engine")
#endif
                        ), additionalInfo)
        {
        }
    };
}
