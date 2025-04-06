#include <stdio.h>
#include <fcntl.h>
#include <sys/types.h>

/* open functions */
int open_int(const char *path, int oflag);
int open_int_mode(const char *path, int oflag, mode_t mode);

/* fcntl functions */
int fcntl_int(int fildes, int cmd);
int fcntl_int_flock(int fildes, int cmd, struct flock* flock);
int fcntl_int_long(int fildes, int cmd, long arg);

/* ioctl functions */
int ioctl_long(int fd, unsigned long request);
int ioctl_long_void(int fd, unsigned long request, void* data);
