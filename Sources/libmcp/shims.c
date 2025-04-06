#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include "shims.h"

/* open functions */
int open_int(const char *path, int oflag) {
    return open(path, oflag);
}
int open_int_mode(const char *path, int oflag, mode_t mode) {
    return open(path, oflag, mode);
}

/* fcntl functions */
int fcntl_int(int fildes, int cmd) {
    return fcntl(fildes, cmd);
}
int fcntl_int_flock(int fildes, int cmd, struct flock* flock) {
    return fcntl(fildes, cmd, flock);
}
int fcntl_int_long(int fildes, int cmd, long arg) {
    return fcntl(fildes, cmd, arg);
}

/* ioctl functions */
int ioctl_long(int fd, unsigned long request) {
    return ioctl(fd, request);
}
int ioctl_long_void(int fd, unsigned long request, void* data) {
    return ioctl(fd, request, data);
}
