#!/bin/bash

# Author: akram.hamed@rsa.com
# Version: 1.0

# this script prints the total ammount of Memory assigned to each process and prints it in a table human readable format, It also Prints CPU Utilization and top 10 file talkers.

# this software is provided "as is", without warranty of any kind, express or implied,
# including but not limited to the warranties of merchantability, fitness for a particular purpose and noninfringement.
# in no event shall the author be liable for any claim, damages or other liability.
# the entire risk as to the quality and performance of the program is with you. should the program prove defective,
# you assume the cost of all necessary servicing, repair or correction.


#....
# Make sure only root can run this script
if [ "$(id -u)" != "0" ]; then
	echo $'\n'
	echo "This script must be run as root, please login as root and try again" 1>&2
	echo $'\n'
	exit 1
fi
# ...

## PRINT SYSTEM INFO

find_sbin_cmd() {
    for base in / /usr/ /usr/local; do
        if [ -e $base/sbin/$1 ]; then
            echo $base/sbin/$1
            exit
        fi
    done
}
FDISK=`which fdisk 2>/dev/null`
LSUSB=`which lsusb 2>/dev/null`
LSPCI=`which lspci 2>/dev/null`
[ -z "$FDISK" ] && FDISK=`find_sbin_cmd fdisk`
[ -z "$LSUSB" ] && LSUSB=`find_sbin_cmd lsusb`
[ -z "$LSPCI" ] && LSPCI=`find_sbin_cmd lspci`

echo "============= Drives ============="
(
sed -n 's/.* \([hs]d[a-f]$\)/\1/p' < /proc/partitions
[ -e /dev/cdrom ] && readlink -f /dev/cdrom | cut -d/ -f3
) |
sort | uniq |
while read disk; do
    echo -n "/dev/$disk: "
    if [ ! -r /dev/$disk ]; then
        echo "permission denied" #could parse /proc for all but
    else
        size=`$FDISK -l /dev/$disk | grep Disk | cut -d' ' -f3-4 | tr -d ,`
        rest=`/sbin/hdparm -i /dev/$disk 2>/dev/null | grep Model`
        rest=`echo $rest` #strip spaces
        echo -n "$rest"
        if [ ! -z "$size" ]; then
            echo ", Size=$size"
        else
            echo
        fi
    fi
done
echo $'\n'
df -ahT
echo $'\n'$'\n'
echo "============= CPUs ============="
grep "model name" /proc/cpuinfo #show CPU(s) info
echo $'\n'
mpstat -P ALL
echo $'\n'$'\n'
echo "============= MEM ============="
KiB=`grep MemTotal /proc/meminfo | tr -s ' ' | cut -d' ' -f2`
MiB=`expr $KiB / 1024`
round=32
echo "`expr \( \( $MiB / $round \) + 1 \) \* $round` MiB"
echo $'\n'
cat /proc/meminfo | head -n 7
echo $'\n'$'\n'

## END PRINT SYSTEM INFO

###########################################################
read -rsp $'Press any key to continue with detailed [MEMORY] report...\n' -n1 key
echo "==============================================================================="
echo $'\n'$'\n'
echo "Detailed Memory Report"
echo " "
python << END

import getopt
import time
import errno
import os
import sys

try:
    import hashlib
    md5_new = hashlib.md5
except ImportError:
    import md5
    md5_new = md5.new


def std_exceptions(etype, value, tb):
    sys.excepthook = sys.__excepthook__
    if issubclass(etype, KeyboardInterrupt):
        pass
    elif issubclass(etype, IOError) and value.errno == errno.EPIPE:
        pass
    else:
        sys.__excepthook__(etype, value, tb)
sys.excepthook = std_exceptions


#   Define some global variables


PAGESIZE = os.sysconf("SC_PAGE_SIZE") / 1024 #KiB
our_pid = os.getpid()

have_pss = 0

class Proc:
    def __init__(self):
        uname = os.uname()
        if uname[0] == "FreeBSD":
            self.proc = '/compat/linux/proc'
        else:
            self.proc = '/proc'

    def path(self, *args):
        return os.path.join(self.proc, *(str(a) for a in args))

    def open(self, *args):
        try:
            if sys.version_info < (3,):
                return open(self.path(*args))
            else:
                return open(self.path(*args), errors='ignore')
        except (IOError, OSError):
            val = sys.exc_info()[1]
            if (val.errno == errno.ENOENT or # kernel thread or process gone
                val.errno == errno.EPERM):
                raise LookupError
            raise

proc = Proc()



#   Functions


def parse_options():
    try:
        long_options = ['split-args', 'help', 'total']
        opts, args = getopt.getopt(sys.argv[1:], "shtp:w:", long_options)
    except getopt.GetoptError:
        sys.stderr.write(help())
        sys.exit(3)

    if len(args):
        sys.stderr.write("Extraneous arguments: %s\n" % args)
        sys.exit(3)

    # ps_mem.py options
    split_args = False
    pids_to_show = None
    watch = None
    only_total = False

    for o, a in opts:
        if o in ('-s', '--split-args'):
            split_args = True
        if o in ('-t', '--total'):
            only_total = True
        if o in ('-h', '--help'):
            sys.stdout.write(help())
            sys.exit(0)
        if o in ('-p',):
            try:
                pids_to_show = [int(x) for x in a.split(',')]
            except:
                sys.stderr.write(help())
                sys.exit(3)
        if o in ('-w',):
            try:
                watch = int(a)
            except:
                sys.stderr.write(help())
                sys.exit(3)

    return (split_args, pids_to_show, watch, only_total)

def help():
    help_msg = 'Usage: ps_mem [OPTION]...\n' \
    'Show program core memory usage\n' \
    '\n' \
    '  -h, -help                   Show this help\n' \
    '  -p <pid>[,pid2,...pidN]     Only show memory usage PIDs in the specified list\n' \
    '  -s, --split-args            Show and separate by, all command line arguments\n' \
    '  -t, --total                 Show only the total value\n' \
    '  -w <N>                      Measure and show process memory every N seconds\n'

    return help_msg

#(major,minor,release)
def kernel_ver():
    kv = proc.open('sys/kernel/osrelease').readline().split(".")[:3]
    last = len(kv)
    if last == 2:
        kv.append('0')
    last -= 1
    while last > 0:
        for char in "-_":
            kv[last] = kv[last].split(char)[0]
        try:
            int(kv[last])
        except:
            kv[last] = 0
        last -= 1
    return (int(kv[0]), int(kv[1]), int(kv[2]))



def getMemStats(pid):
    global have_pss
    mem_id = pid #unique
    Private_lines = []
    Shared_lines = []
    Pss_lines = []
    Rss = (int(proc.open(pid, 'statm').readline().split()[1])
           * PAGESIZE)
    if os.path.exists(proc.path(pid, 'smaps')): #stat
        digester = md5_new()
        for line in proc.open(pid, 'smaps').readlines(): #open
            # Note we checksum smaps as maps is usually but
            # not always different for separate processes.
            if sys.version_info < (3,):
                digester.update(line)
            else:
                digester.update(bytes(line,'latin1'))
            if line.startswith("Shared"):
                Shared_lines.append(line)
            elif line.startswith("Private"):
                Private_lines.append(line)
            elif line.startswith("Pss"):
                have_pss = 1
                Pss_lines.append(line)
        mem_id = digester.hexdigest()
        Shared = sum([int(line.split()[1]) for line in Shared_lines])
        Private = sum([int(line.split()[1]) for line in Private_lines])
        #Note Shared + Private = Rss above
        #The Rss in smaps includes video card mem etc.
        if have_pss:
            pss_adjust = 0.5 # add 0.5KiB as this avg error due to trunctation
            Pss = sum([float(line.split()[1])+pss_adjust for line in Pss_lines])
            Shared = Pss - Private
    elif (2,6,1) <= kernel_ver() <= (2,6,9):
        Shared = 0 #lots of overestimation, but what can we do?
        Private = Rss
    else:
        Shared = int(proc.open(pid, 'statm').readline().split()[2])
        Shared *= PAGESIZE
        Private = Rss - Shared
    return (Private, Shared, mem_id)


def getCmdName(pid, split_args):
    cmdline = proc.open(pid, 'cmdline').read().split("\0")
    if cmdline[-1] == '' and len(cmdline) > 1:
        cmdline = cmdline[:-1]

    path = proc.path(pid, 'exe')
    try:
        path = os.readlink(path)
        # Some symlink targets were seen to contain NULs on RHEL 5 at least
        # https://github.com/pixelb/scripts/pull/10, so take string up to NUL
        path = path.split('\0')[0]
    except OSError:
        val = sys.exc_info()[1]
        if (val.errno == errno.ENOENT or # either kernel thread or process gone
            val.errno == errno.EPERM):
            raise LookupError
        raise

    if split_args:
        return " ".join(cmdline)
    if path.endswith(" (deleted)"):
        path = path[:-10]
        if os.path.exists(path):
            path += " [updated]"
        else:
            #The path could be have prelink stuff so try cmdline
            #which might have the full path present. This helped for:
            #/usr/libexec/notification-area-applet.#prelink#.fX7LCT (deleted)
            if os.path.exists(cmdline[0]):
                path = cmdline[0] + " [updated]"
            else:
                path += " [deleted]"
    exe = os.path.basename(path)
    cmd = proc.open(pid, 'status').readline()[6:-1]
    if exe.startswith(cmd):
        cmd = exe #show non truncated version
        #Note because we show the non truncated name
        #one can have separated programs as follows:
        #584.0 KiB +   1.0 MiB =   1.6 MiB    mozilla-thunder (exe -> bash)
        # 56.0 MiB +  22.2 MiB =  78.2 MiB    mozilla-thunderbird-bin
    if sys.version_info < (3,):
        return cmd
    else:
        return cmd.encode(errors='replace').decode()


#The following matches "du -h" output
def human(num, power="Ki", units=None):
    if units is None:
        powers = ["Ki", "Mi", "Gi", "Ti"]
        while num >= 1000: #4 digits
            num /= 1024.0
            power = powers[powers.index(power)+1]
        return "%.1f %sB" % (num, power)
    else:
        return "%.f" % ((num * 1024) / units)


def cmd_with_count(cmd, count):
    if count > 1:
        return "%s (%u)" % (cmd, count)
    else:
        return cmd


def shared_val_accuracy():
    """http://wiki.apache.org/spamassassin/TopSharedMemoryBug"""
    kv = kernel_ver()
    pid = os.getpid()
    if kv[:2] == (2,4):
        if proc.open('meminfo').read().find("Inact_") == -1:
            return 1
        return 0
    elif kv[:2] == (2,6):
        if os.path.exists(proc.path(pid, 'smaps')):
            if proc.open(pid, 'smaps').read().find("Pss:")!=-1:
                return 2
            else:
                return 1
        if (2,6,1) <= kv <= (2,6,9):
            return -1
        return 0
    elif kv[0] > 2 and os.path.exists(proc.path(pid, 'smaps')):
        return 2
    else:
        return 1

def show_shared_val_accuracy( possible_inacc, only_total=False ):
    level = ("Warning","Error")[only_total]
    if possible_inacc == -1:
        sys.stderr.write(
         "%s: Shared memory is not reported by this system.\n" % level
        )
        sys.stderr.write(
         "Values reported will be too large, and totals are not reported\n"
        )
    elif possible_inacc == 0:
        sys.stderr.write(
         "%s: Shared memory is not reported accurately by this system.\n" % level
        )
        sys.stderr.write(
         "Values reported could be too large, and totals are not reported\n"
        )
    elif possible_inacc == 1:
        sys.stderr.write(
         "%s: Shared memory is slightly over-estimated by this system\n"
         "for each program, so totals are not reported.\n" % level
        )
    sys.stderr.close()
    if only_total and possible_inacc != 2:
        sys.exit(1)

def get_memory_usage( pids_to_show, split_args, include_self=False, only_self=False ):
    cmds = {}
    shareds = {}
    mem_ids = {}
    count = {}
    for pid in os.listdir(proc.path('')):
        if not pid.isdigit():
            continue
        pid = int(pid)

        # Some filters
        if only_self and pid != our_pid:
            continue
        if pid == our_pid and not include_self:
            continue
        if pids_to_show is not None and pid not in pids_to_show:
            continue

        try:
            cmd = getCmdName(pid, split_args)
        except LookupError:
            #operation not permitted
            #kernel threads don't have exe links or
            #process gone
            continue

        try:
            private, shared, mem_id = getMemStats(pid)
        except RuntimeError:
            continue #process gone
        if shareds.get(cmd):
            if have_pss: #add shared portion of PSS together
                shareds[cmd] += shared
            elif shareds[cmd] < shared: #just take largest shared val
                shareds[cmd] = shared
        else:
            shareds[cmd] = shared
        cmds[cmd] = cmds.setdefault(cmd, 0) + private
        if cmd in count:
            count[cmd] += 1
        else:
            count[cmd] = 1
        mem_ids.setdefault(cmd, {}).update({mem_id:None})

    #Add shared mem for each program
    total = 0
    for cmd in cmds:
        cmd_count = count[cmd]
        if len(mem_ids[cmd]) == 1 and cmd_count > 1:
            # Assume this program is using CLONE_VM without CLONE_THREAD
            # so only account for one of the processes
            cmds[cmd] /= cmd_count
            if have_pss:
                shareds[cmd] /= cmd_count
        cmds[cmd] = cmds[cmd] + shareds[cmd]
        total += cmds[cmd] #valid if PSS available

    sorted_cmds = sorted(cmds.items(), key=lambda x:x[1])
    sorted_cmds = [x for x in sorted_cmds if x[1]]

    return sorted_cmds, shareds, count, total

def print_header():
    sys.stdout.write(" Private  +   Shared  =  RAM used\tProgram\n\n")

def print_memory_usage(sorted_cmds, shareds, count, total):
    for cmd in sorted_cmds:
        sys.stdout.write("%9s + %9s = %9s\t%s\n" %
                         (human(cmd[1]-shareds[cmd[0]]),
                          human(shareds[cmd[0]]), human(cmd[1]),
                          cmd_with_count(cmd[0], count[cmd[0]])))
    if have_pss:
        sys.stdout.write("%s\n%s%9s\n%s\n" %
                         ("-" * 33, " " * 24, human(total), "=" * 33))

def verify_environment():
    if os.geteuid() != 0:
        sys.stderr.write("Sorry, root permission required.\n")
        if __name__ == '__main__':
            sys.stderr.close()
            sys.exit(1)

    try:
        kv = kernel_ver()
    except (IOError, OSError):
        val = sys.exc_info()[1]
        if val.errno == errno.ENOENT:
            sys.stderr.write(
              "Couldn't access " + proc.path('') + "\n"
              "Only GNU/Linux and FreeBSD (with linprocfs) are supported\n")
            sys.exit(2)
        else:
            raise

if __name__ == '__main__':
    split_args, pids_to_show, watch, only_total = parse_options()
    verify_environment()

    if not only_total:
        print_header()

    if watch is not None:
        try:
            sorted_cmds = True
            while sorted_cmds:
                sorted_cmds, shareds, count, total = get_memory_usage( pids_to_show, split_args )
                if only_total and have_pss:
                    sys.stdout.write(human(total, units=1)+'\n')
                elif not only_total:
                    print_memory_usage(sorted_cmds, shareds, count, total)
                time.sleep(watch)
            else:
                sys.stdout.write('Process does not exist anymore.\n')
        except KeyboardInterrupt:
            pass
    else:
        # This is the default behavior
        sorted_cmds, shareds, count, total = get_memory_usage( pids_to_show, split_args )
        if only_total and have_pss:
            sys.stdout.write(human(total, units=1)+'\n')
        elif not only_total:
            print_memory_usage(sorted_cmds, shareds, count, total)

    
    sys.stdout.close()

    vm_accuracy = shared_val_accuracy()
    show_shared_val_accuracy( vm_accuracy, only_total )
	
END

echo $'\n'$'\n'

read -rsp $'Press any key to continue with top 10 [PROCESSES] consuming CPU...\n' -n1 key
echo "==============================================================================="
echo $'\n'
ps -eo pcpu,pid,user,args | sort -k 1 -r | head -10 | cut -d " " -f1,2,3,4,5,6
echo $'\n'$'\n'

read -rsp $'Press any key to continue with top 10 [FILES] according to file size...\n' -n1 key
echo "==============================================================================="
echo $'\n'
find / -size +20000k -exec ls -lh {} \; 2> /dev/null | awk '{ print $NF ": " $5 }' | sort -nrk 2,2 | head
echo $'\n'$'\n'
