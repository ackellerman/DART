import argparse
import datetime
import os
import pathlib
import sys
from wrfhydropy.core.ensemble_tools import get_ens_dotfile_end_datetime

parser = argparse.ArgumentParser(
    description='Get the time of a HydroDartRun Ensemble'
)

parser.add_argument(
    '--run_dir',
    required=False,
    metavar='/abs/path/to/run/directory',
    help='Path to the experiment directory. (Default is director where this script or a ' +
         'symlink (not resolved) to it lives).',
    default= os.path.dirname(os.path.abspath(__file__))
)

parser.add_argument(
    '--with_previous',
    required=False,
    metavar='delta_time_hours',
    help='returns a tuple"previous|current"',
    default='0'
)

args = parser.parse_args()
run_dir = pathlib.PosixPath(args.run_dir)
with_previous = int(args.with_previous)

current_time = get_ens_dotfile_end_datetime(run_dir)

if with_previous != 0:
    previous_time = current_time - datetime.timedelta(hours=with_previous)
    print(
        previous_time.strftime('%Y-%m-%d_%H:%M') + 
        '|' + 
        current_time.strftime('%Y-%m-%d_%H:%M')
    )
else:
    print(current_time.strftime('%Y-%m-%d_%H:%M'))
    
sys.exit()
