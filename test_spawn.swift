import Foundation
import Darwin

var pid: pid_t = 0
var ret = posix_spawn(&pid, "/bin/ls", nil, nil, nil, environ)
print(ret)
