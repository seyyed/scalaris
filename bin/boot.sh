#!/bin/bash
# Copyright 2007-2008 Konrad-Zuse-Zentrum für Informationstechnik Berlin
# 
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
# 
#        http://www.apache.org/licenses/LICENSE-2.0
# 
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

DIRNAME=`dirname $0`
GLOBAL_CFG="$DIRNAME/scalaris.cfg.sh"
LOCAL_CFG="$DIRNAME/scalaris.local.cfg.sh"
if [ -f "$GLOBAL_CFG" ] ; then source "$GLOBAL_CFG" ; fi
if [ -f "$LOCAL_CFG" ] ; then source "$LOCAL_CFG" ; fi

export ERL_MAX_PORTS=16384
<<<<<<< .working
erl $ERL_OPTS +A 4 -setcookie "chocolate chip cookie" -pa ../contrib/yaws/ebin -pa ../ebin -yaws embedded true -connect_all false -hidden -sname boot@localhost -s boot 
=======
erl $ERL_OPTS +S 4 +A 4 -setcookie "chocolate chip cookie" -pa ../contrib/log4erl/ebin -pa ../contrib/yaws/ebin -pa ../ebin -yaws embedded true -connect_all false -sname boot@localhost -s boot 
>>>>>>> .merge-right.r186
