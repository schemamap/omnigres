if(APPLE)
    if(IS_DIRECTORY /opt/homebrew/opt/openssl@3)
        set(OPENSSL_ROOT_DIR /opt/homebrew/opt/openssl@3)
    elseif(IS_DIRECTORY /opt/homebrew/opt/openssl@1.1)
        set(OPENSSL_ROOT_DIR /opt/homebrew/opt/openssl@1.1)
    elseif(IS_DIRECTORY /opt/homebrew/opt/openssl)
        set(OPENSSL_ROOT_DIR /opt/homebrew/opt/openssl)
    else()
        message(FATAL_ERROR "No OpenSSL found, use homebrew to install one")
    endif()
endif()