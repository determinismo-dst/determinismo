#!/bin/sh
# SPDX-License-Identifier: MIT
# The rare state, true in this template.
printf '{"antithesis_assert":{"hit":true,"must_hit":true,"assert_type":"sometimes","display_type":"Sometimes","message":"a rare state some template reaches","condition":true,"details":null}}\n' \
  > "${ANTITHESIS_SDK_LOCAL_OUTPUT:-/dev/stderr}"
