#!/bin/bash
# Patches author: backslashxx @ Github
# Shell authon: JackA1ltman <cs2dtzq@163.com>
# Tested kernel versions: 5.4, 4.19, 4.14, 4.9, 4.4, 3.18, 3.10, 3.4
# 20250309

patch_files=(
    fs/exec.c
    fs/open.c
    fs/read_write.c
    fs/stat.c
    drivers/input/input.c
    drivers/tty/pty.c
)

KERNEL_VERSION=$(head -n 3 Makefile | grep -E 'VERSION|PATCHLEVEL' | awk '{print $3}' | paste -sd '.')
FIRST_VERSION=$(echo "$KERNEL_VERSION" | awk -F '.' '{print $1}')
SECOND_VERSION=$(echo "$KERNEL_VERSION" | awk -F '.' '{print $2}')

for i in "${patch_files[@]}"; do

    if grep -q "ksu" "$i"; then
        echo "Warning: $i contains KernelSU"
        continue
    fi

    case $i in

    # fs/ changes
    ## exec.c
    fs/exec.c)
        sed -i '0,/SYSCALL_DEFINE3(execve,/ {
                                                      /SYSCALL_DEFINE3(execve,/i \
                                                  #ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execve_sucompat(int *fd, const char __user **filename_user,\n\t\t   void *__never_use_argv, void *__never_use_envp,\n\t\t   int *__never_use_flags);\nextern int ksu_handle_execve_ksud(const char __user *filename_user,\n\t\tconst char __user *const __user *__argv);\n#ifdef CONFIG_COMPAT  \/\/ 32-on-64 support\nextern int ksu_handle_compat_execve_ksud(const char __user *filename_user,\n\t\tconst compat_uptr_t __user *__argv);\n#endif\n#endif
                                                  }' fs/exec.c

        sed -i '/do_execve *(/,/^}/ {
/struct user_arg_ptr envp = { .ptr.native = __envp };/a\
#ifdef CONFIG_KSU\
\tif (unlikely(ksu_execveat_hook))\
\t\tksu_handle_execveat((int *)AT_FDCWD, &filename, &argv, &envp, 0);\
\telse\
\t\tksu_handle_execveat_sucompat((int *)AT_FDCWD, &filename, NULL, NULL, NULL);\
#endif
}' fs/exec.c
        sed -i ':a;N;$!ba;s/\(return do_execveat_common(AT_FDCWD, filename, argv, envp, 0);\)/\n#ifdef CONFIG_KSU\n\tif (!ksu_execveat_hook)\n\t\tksu_handle_execveat_sucompat((int *)AT_FDCWD, \&filename, NULL, NULL, NULL); \/* 32-bit su *\/\n#endif\n\1/2' fs/exec.c
        ;;

    ## open.c
    fs/open.c)
        if grep -q "return do_faccessat(dfd, filename, mode);" fs/open.c; then
            sed -i '/return do_faccessat(dfd, filename, mode);/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\tint *flags);\n#endif' fs/open.c
        elif [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 18 ]; then
            sed -i '/if (mode & ~S_IRWXO)/i \#ifdef CONFIG_KSU\n\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n#endif' fs/open.c
        else
            sed -i ':a;N;$!ba;s/\(unsigned int lookup_flags = LOOKUP_FOLLOW;\)/\1\n#ifdef CONFIG_KSU\n\tksu_handle_faccessat(\&dfd, \&filename, \&mode, NULL);\n#endif/2' fs/open.c

        fi
        sed -i '0,/SYSCALL_DEFINE3(faccessat, int, dfd, const char __user \*, filename, int, mode)/s//#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n\t\t\t                    int *flags);\n#endif\n&/' fs/open.c
        ;;

    ## read_write.c
    fs/read_write.c)
        if grep -q "return ksys_read(fd, buf, count);" fs/read_write.c; then
            sed -i '/return ksys_read(fd, buf, count);/i\#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, &buf, &count);\n#endif' fs/read_write.c
        elif [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 18 ]; then
            sed -i '0,/ret = vfs_read(file, buf, count, &pos);/ { /ret = vfs_read(file, buf, count, &pos);/i \#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, &buf, &count);\n#endif
                                                           }' fs/read_write.c
        else
            sed -i '0,/if (f.file) {/s//if (f.file) {\n#ifdef CONFIG_KSU\n\tif (unlikely(ksu_vfs_read_hook))\n\t\tksu_handle_sys_read(fd, \&buf, \&count);\n#endif/' fs/read_write.c
        fi
        sed -i '/SYSCALL_DEFINE3(read, unsigned int, fd, char __user \*, buf, size_t, count)/i\#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_sys_read(unsigned int fd, char __user **buf_ptr,\n\t\t\tsize_t *count_ptr);\n#endif' fs/read_write.c
        ;;

    ## stat.c
    fs/stat.c)
        sed -i '/#if !defined(__ARCH_WANT_STAT64) || defined(__ARCH_WANT_SYS_NEWFSTATAT)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif' fs/stat.c
        sed -i '0,/\terror = vfs_fstatat(dfd, filename, &stat, flag);/s//#ifdef CONFIG_KSU\n\tksu_handle_stat(\&dfd, \&filename, \&flag);\n#endif\n&/' fs/stat.c
        sed -i ':a;N;$!ba;s/\(\terror = vfs_fstatat(dfd, filename, &stat, flag);\)/#ifdef CONFIG_KSU\n\tksu_handle_stat(\&dfd, \&filename, \&flag);\n#endif\n\1/2' fs/stat.c
        ;;

    # drivers/input changes
    ## input.c
    drivers/input/input.c)
        sed -i '0,/void input_event(struct input_dev \*dev,/s//#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int \*type, unsigned int \*code, int \*value);\n#endif\n&/' drivers/input/input.c
        sed -i '0,/\tif (is_event_supported(type, dev->evbit, EV_MAX)) {/s//#ifdef CONFIG_KSU\n\tif (unlikely(ksu_input_hook))\n\t\tksu_handle_input_handle_event(\&type, \&code, \&value);\n#endif\n&/' drivers/input/input.c
        ;;

    # drivers/tty changes
    ## pty.c
    drivers/tty/pty.c)
        sed -i '0,/static struct tty_struct \*pts_unix98_lookup(struct tty_driver \*driver,/s//#ifdef CONFIG_KSU\nextern int ksu_handle_devpts(struct inode*);\n#endif\n&/' drivers/tty/pty.c
        sed -i ':a;N;$!ba;s/\(\tmutex_lock(&devpts_mutex);\)/#ifdef CONFIG_KSU\n\tksu_handle_devpts((struct inode *)file->f_path.dentry->d_inode);\n#endif\n\1/2' drivers/tty/pty.c
        ;;

    # security/ changes
    ## security.c
    security/security.c)
        if [ "$FIRST_VERSION" -lt 4 ] && [ "$SECOND_VERSION" -lt 18 ]; then
            sed -i '/#ifdef CONFIG_BPF_SYSCALL/i \#ifdef CONFIG_KSU\nextern int ksu_handle_prctl(int option, unsigned long arg2, unsigned long arg3,\n\t\t   unsigned long arg4, unsigned long arg5);\nextern int ksu_handle_rename(struct dentry *old_dentry, struct dentry *new_dentry);\nextern int ksu_handle_setuid(struct cred *new, const struct cred *old);\n#endif' security/security.c
            sed -i '/if (unlikely(IS_PRIVATE(old_dentry->d_inode) ||/i \#ifdef CONFIG_KSU\n\tksu_handle_rename(old_dentry, new_dentry);\n#endif' security/security.c
            sed -i '/return security_ops->task_fix_setuid(new, old, flags);/i \#ifdef CONFIG_KSU\n\tksu_handle_setuid(new, old);\n#endif' security/security.c
            sed -i '/return security_ops->task_prctl(option, arg2, arg3, arg4, arg5);/i \#ifdef CONFIG_KSU\n\tksu_handle_prctl(option, arg2, arg3, arg4, arg5);\n#endif' security/security.c
        fi
        ;;
    esac

done
