! DART software - Copyright 2004 - 2013 UCAR. This open source software is
! provided by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!
! $Id$

module filter_mod

!------------------------------------------------------------------------------
use types_mod,             only : r8, i8, missing_r8, metadatalength
use obs_sequence_mod,      only : read_obs_seq, obs_type, obs_sequence_type,                  &
                                  get_obs_from_key, set_copy_meta_data, get_copy_meta_data,   &
                                  get_obs_def, get_time_range_keys, set_obs_values, set_obs,  &
                                  write_obs_seq, get_num_obs, get_obs_values, init_obs,       &
                                  assignment(=), get_num_copies, get_qc, get_num_qc, set_qc,  &
                                  static_init_obs_sequence, destroy_obs, read_obs_seq_header, &
                                  set_qc_meta_data, get_first_obs, get_obs_time_range,        &
                                  delete_obs_from_seq, delete_seq_head,                       &
                                  delete_seq_tail, replace_obs_values, replace_qc,            &
                                  destroy_obs_sequence, get_qc_meta_data, add_qc
                                  
use obs_def_mod,           only : obs_def_type, get_obs_def_error_variance, get_obs_def_time, &
                                  get_obs_kind
use obs_def_utilities_mod, only : set_debug_fwd_op
use time_manager_mod,      only : time_type, get_time, set_time, operator(/=), operator(>),   &
                                  operator(-), print_time
use utilities_mod,         only : register_module,  error_handler, E_ERR, E_MSG, E_DBG,       &
                                  logfileunit, nmlfileunit, timestamp,  &
                                  do_output, find_namelist_in_file, check_namelist_read,      &
                                  open_file, close_file, do_nml_file, do_nml_term
use assim_model_mod,       only : static_init_assim_model, get_model_size,                    &
                                  netcdf_file_type, init_diag_output, finalize_diag_output,   &
                                  aoutput_diagnostics, end_assim_model,                       &
                                  pert_model_copies, pert_model_state
use assim_tools_mod,       only : filter_assim, set_assim_tools_trace, get_missing_ok_status, &
                                  test_state_copies
use obs_model_mod,         only : move_ahead, advance_state, set_obs_model_trace
use ensemble_manager_mod,  only : init_ensemble_manager, end_ensemble_manager,                &
                                  ensemble_type, get_copy, get_my_num_copies, put_copy,       &
                                  all_vars_to_all_copies, all_copies_to_all_vars,             &
                                  compute_copy_mean, compute_copy_mean_sd,                    &
                                  compute_copy_mean_var, duplicate_ens, get_copy_owner_index, &
                                  get_ensemble_time, set_ensemble_time, broadcast_copy,       &
                                  prepare_to_read_from_vars, prepare_to_write_to_vars,        &
                                  prepare_to_read_from_copies,  get_my_num_vars,              &
                                  prepare_to_write_to_copies, get_ensemble_time,              &
                                  map_task_to_pe,  map_pe_to_task, prepare_to_update_copies,  &
                                  copies_in_window, set_num_extra_copies, get_allow_transpose, &
                                  all_copies_to_all_vars, allocate_single_copy,               &
                                  get_single_copy, put_single_copy, deallocate_single_copy
use adaptive_inflate_mod,  only : adaptive_inflate_end, do_varying_ss_inflate,                &
                                  do_single_ss_inflate, inflate_ens, adaptive_inflate_init,   &
                                  do_obs_inflate, adaptive_inflate_type,                      &
                                  output_inflate_diagnostics, log_inflation_info, &
                                  get_minmax_task_zero_distrib
use mpi_utilities_mod,     only : initialize_mpi_utilities, finalize_mpi_utilities,           &
                                  my_task_id, task_sync, broadcast_send, broadcast_recv,      &
                                  task_count
use smoother_mod,          only : smoother_read_restart, advance_smoother,                    &
                                  smoother_gen_copy_meta_data, smoother_write_restart,        &
                                  init_smoother, do_smoothing, smoother_mean_spread,          &
                                  smoother_assim,            &
                                  smoother_ss_diagnostics, smoother_end, set_smoother_trace

use random_seq_mod,        only : random_seq_type, init_random_seq, random_gaussian

use distributed_state_mod, only : create_state_window, free_state_window

use state_vector_io_mod,   only : read_transpose, transpose_write, state_vector_io_init, &
                                  setup_read_write, turn_read_copy_on, turn_write_copy_on, &
                                  turn_write_copy_off,read_ensemble_restart, write_ensemble_restart, &
                                  filter_write_restart_direct, filter_read_restart_direct

use io_filenames_mod,      only : io_filenames_init, get_input_file, set_filenames

use state_structure_mod,   only : get_num_domains, static_init_state_type, add_domain

!use mpi

use forward_operator_mod,  only : get_obs_ens_distrib_state 
use quality_control_mod,   only : initialize_qc

use state_space_diag_mod,  only : filter_state_space_diagnostics

!------------------------------------------------------------------------------

implicit none
private

public :: filter_sync_keys_time, &
          filter_set_initial_time, &
          filter_main

! version controlled file description for error handling, do not edit
character(len=256), parameter :: source   = &
   "$URL$"
character(len=32 ), parameter :: revision = "$Revision$"
character(len=128), parameter :: revdate  = "$Date$"

! Some convenient global storage items
character(len=129)      :: msgstring
type(obs_type)          :: observation

integer                 :: trace_level, timestamp_level

! Defining whether diagnostics are for prior or posterior
integer, parameter :: PRIOR_DIAG = 0, POSTERIOR_DIAG = 2

!----------------------------------------------------------------
! Namelist input with default values
!
integer  :: async = 0, ens_size = 20
logical  :: start_from_restart  = .false.
logical  :: output_restart      = .false.
logical  :: output_restart_mean = .false.
integer  :: tasks_per_model_advance = 1
! if init_time_days and seconds are negative initial time is 0, 0
! for no restart or comes from restart if restart exists
integer  :: init_time_days    = 0
integer  :: init_time_seconds = 0
! Time of first and last observations to be used from obs_sequence
! If negative, these are not used
integer  :: first_obs_days      = -1
integer  :: first_obs_seconds   = -1
integer  :: last_obs_days       = -1
integer  :: last_obs_seconds    = -1
! Assimilation window; defaults to model timestep size.
integer  :: obs_window_days     = -1
integer  :: obs_window_seconds  = -1
! Control diagnostic output for state variables
integer  :: num_output_state_members = 0
integer  :: num_output_obs_members   = 0
integer  :: output_interval     = 1
integer  :: num_groups          = 1
logical  :: output_forward_op_errors = .false.
logical  :: output_timestamps        = .false.
logical  :: trace_execution          = .false.
logical  :: silence                  = .false.
logical  :: direct_netcdf_read = .true.  ! default to read from netcdf file
logical  :: direct_netcdf_write = .true. ! default to write to netcdf file

! perturbation namelist parameters for.  For now these are in filter
logical  :: perturb_restarts = .false.
real(r8) :: perturbation_amplitude = 0.2_r8
logical  :: distributed_state = .true. ! Default to do state complete forward operators.

! what should you do about diagnostic files.

logical  :: diagnostic_files = .false. ! what should be the default

character(len = 129) :: obs_sequence_in_name  = "obs_seq.out",    &
                        obs_sequence_out_name = "obs_seq.final",  &
                        restart_in_file_name  = 'filter_ics',     &
                        restart_out_file_name = 'filter_restart', &
                        adv_ens_command       = './advance_model.csh'

!                  == './advance_model.csh'    -> advance ensemble using a script

! Inflation namelist entries follow, first entry for prior, second for posterior
! inf_flavor is 0:none, 1:obs space, 2: varying state space, 3: fixed state_space
integer              :: inf_flavor(2)             = 0
logical              :: inf_initial_from_restart(2)    = .false.
logical              :: inf_sd_initial_from_restart(2) = .false.

! old way
logical              :: inf_output_restart(2)     = .false.
! new way
!logical              :: inf_output_prior(2) = .false. ! mean sd
!logical              :: inf_output_post(2)  = .false. ! mean sd

logical              :: inf_deterministic(2)      = .true.
character(len = 129) :: inf_in_file_name(2)       = 'not_initialized',    &
                        inf_out_file_name(2)      = 'not_initialized',    &
                        inf_diag_file_name(2)     = 'not_initialized'
real(r8)             :: inf_initial(2)            = 1.0_r8
real(r8)             :: inf_sd_initial(2)         = 0.0_r8
real(r8)             :: inf_damping(2)            = 1.0_r8
real(r8)             :: inf_lower_bound(2)        = 1.0_r8
real(r8)             :: inf_upper_bound(2)        = 1000000.0_r8
real(r8)             :: inf_sd_lower_bound(2)     = 0.0_r8
logical              :: output_inflation          = .true. ! This is for the diagnostic files, no separate option for prior and posterior

namelist /filter_nml/ async, adv_ens_command, ens_size, tasks_per_model_advance,    &
   start_from_restart, output_restart, obs_sequence_in_name, obs_sequence_out_name, &
   restart_in_file_name, restart_out_file_name, init_time_days, init_time_seconds,  &
   first_obs_days, first_obs_seconds, last_obs_days, last_obs_seconds,              &
   obs_window_days, obs_window_seconds, &
   num_output_state_members, num_output_obs_members, output_restart_mean,           &
   output_interval, num_groups, trace_execution,                 &
   output_forward_op_errors, output_timestamps,                 &
   inf_flavor, inf_initial_from_restart, inf_sd_initial_from_restart,               &
   inf_output_restart, inf_deterministic, inf_in_file_name, inf_damping,            &
   inf_out_file_name, inf_diag_file_name, inf_initial, inf_sd_initial,              &
   inf_lower_bound, inf_upper_bound, inf_sd_lower_bound, perturb_restarts,          &
   silence, direct_netcdf_read, direct_netcdf_write, diagnostic_files, output_inflation, &
   distributed_state


!----------------------------------------------------------------

contains

!----------------------------------------------------------------
!> The code is distributed except:
!> * Task 0 still writes the obs_sequence file, so there is a transpose (copies to vars) and 
!> sending the obs_fwd_op_ens_handle%vars to task 0. Keys is also size obs%vars.
!> * You have to have state_ens_handle%vars to read dart restarts and write dart diagnostics

subroutine filter_main()

type(ensemble_type)         :: state_ens_handle, obs_fwd_op_ens_handle, qc_ens_handle
type(obs_sequence_type)     :: seq
type(netcdf_file_type)      :: PriorStateUnit, PosteriorStateUnit
type(time_type)             :: time1, first_obs_time, last_obs_time
type(time_type)             :: curr_ens_time, next_ens_time, window_time
type(adaptive_inflate_type) :: prior_inflate, post_inflate

integer,    allocatable :: keys(:)
integer(i8)             :: model_size
integer                 :: i, iunit, io, time_step_number, num_obs_in_set
integer                 :: ierr, last_key_used, key_bounds(2)
integer                 :: in_obs_copy, obs_val_index
integer                 :: output_state_mean_index, output_state_spread_index
integer                 :: prior_obs_mean_index, posterior_obs_mean_index
integer                 :: prior_obs_spread_index, posterior_obs_spread_index
! Global indices into ensemble storage - why are these in filter?
integer                 :: ENS_MEAN_COPY, ENS_SD_COPY, PRIOR_INF_COPY, PRIOR_INF_SD_COPY
integer                 :: POST_INF_COPY, POST_INF_SD_COPY
! to avoid writing the prior diag
integer                 :: SPARE_COPY_MEAN, SPARE_COPY_SPREAD
integer                 :: SPARE_COPY_INF_MEAN, SPARE_COPY_INF_SPREAD
integer                 :: OBS_VAL_COPY, OBS_ERR_VAR_COPY, OBS_KEY_COPY
integer                 :: OBS_GLOBAL_QC_COPY,OBS_EXTRA_QC_COPY
integer                 :: OBS_MEAN_START, OBS_MEAN_END
integer                 :: OBS_VAR_START, OBS_VAR_END, TOTAL_OBS_COPIES
integer                 :: input_qc_index, DART_qc_index
integer                 :: mean_owner, mean_owners_index
logical                 :: read_time_from_file, interf_provided
!HK
integer :: owner, owners_index
integer :: num_extras ! the extra ensemble copies
logical :: spare_copies ! if you are keeping around prior copies to write at the end

!HK 
doubleprecision start, finish ! for timing with MPI_WTIME

logical                 :: ds, all_gone, allow_missing

! HK
real(r8), allocatable   :: results(:,:)
integer                 :: ii, reps
real(r8), allocatable   :: temp_ens(:)
real(r8), allocatable   :: prior_qc_copy(:)
character*20 task_str, file_obscopies, file_results

!HK debug
logical :: write_flag
! This is for perturbing state when var complete for bitwise checks with the trunk
logical :: perturb_bitwise = .false.

call filter_initialize_modules_used() ! static_init_model called in here

! Read the namelist entry
call find_namelist_in_file("input.nml", "filter_nml", iunit)
read(iunit, nml = filter_nml, iostat = io)
call check_namelist_read(iunit, io, "filter_nml")

! Record the namelist values used for the run ...
if (do_nml_file()) write(nmlfileunit, nml=filter_nml)
if (do_nml_term()) write(     *     , nml=filter_nml)

if (task_count() == 1) distributed_state = .true.

call set_debug_fwd_op(output_forward_op_errors)
call set_trace(trace_execution, output_timestamps, silence)

call     trace_message('Filter start')
call timestamp_message('Filter start')

! Make sure ensemble size is at least 2 (NEED MANY OTHER CHECKS)
if(ens_size < 2) then
   write(msgstring, *) 'ens_size in namelist is ', ens_size, ': Must be > 1'
   call error_handler(E_ERR,'filter_main', msgstring, source, revision, revdate)
endif

! informational message to log
write(msgstring, '(A,I5)') 'running with an ensemble size of ', ens_size
call error_handler(E_MSG,'filter:', msgstring, source, revision, revdate)

! See if smoothing is turned on
ds = do_smoothing()

! Make sure inflation options are legal
do i = 1, 2
   if(inf_flavor(i) < 0 .or. inf_flavor(i) > 3) then
      write(msgstring, *) 'inf_flavor=', inf_flavor(i), ' Must be 0, 1, 2, 3 '
      call error_handler(E_ERR,'filter_main', msgstring, source, revision, revdate)
   endif
   if(inf_damping(i) < 0.0_r8 .or. inf_damping(i) > 1.0_r8) then
      write(msgstring, *) 'inf_damping=', inf_damping(i), ' Must be 0.0 <= d <= 1.0'
      call error_handler(E_ERR,'filter_main', msgstring, source, revision, revdate)
   endif
end do

! Observation space inflation for posterior not currently supported
if(inf_flavor(2) == 1) call error_handler(E_ERR, 'filter_main', &
   'Posterior observation space inflation (type 1) not supported', source, revision, revdate)

! Setup the indices into the ensemble storage
spare_copies = .true.
if (num_output_state_members > 0) spare_copies = .false.
if (diagnostic_files) spare_copies = .false. ! No point writing out this info twice
if (spare_copies) then
   num_extras = 10  ! six plus spare copies
else
   num_extras = 6
endif

! state
ENS_MEAN_COPY        = ens_size + 1
ENS_SD_COPY          = ens_size + 2
PRIOR_INF_COPY       = ens_size + 3
PRIOR_INF_SD_COPY    = ens_size + 4
POST_INF_COPY        = ens_size + 5
POST_INF_SD_COPY     = ens_size + 6
 ! Aim: to hang on to the prior_inf_copy which would have been written to the Prior_Diag.nc - and others if we need them
SPARE_COPY_MEAN       = ens_size + 7
SPARE_COPY_SPREAD     = ens_size + 8
SPARE_COPY_INF_MEAN   = ens_size + 9
SPARE_COPY_INF_SPREAD = ens_size + 10

! observation
OBS_ERR_VAR_COPY     = ens_size + 1
OBS_VAL_COPY         = ens_size + 2
OBS_KEY_COPY         = ens_size + 3
OBS_GLOBAL_QC_COPY   = ens_size + 4
OBS_EXTRA_QC_COPY    = ens_size + 5
OBS_MEAN_START       = ens_size + 6
OBS_MEAN_END         = OBS_MEAN_START + num_groups - 1
OBS_VAR_START        = OBS_MEAN_START + num_groups
OBS_VAR_END          = OBS_VAR_START + num_groups - 1

TOTAL_OBS_COPIES = ens_size + 5 + 2*num_groups

! Can't output more ensemble members than exist
if(num_output_state_members > ens_size) num_output_state_members = ens_size
if(num_output_obs_members   > ens_size) num_output_obs_members   = ens_size

call     trace_message('Before setting up space for observations')
call timestamp_message('Before setting up space for observations')

! Initialize the obs_sequence; every pe gets a copy for now
call filter_setup_obs_sequence(seq, in_obs_copy, obs_val_index, input_qc_index, DART_qc_index)

call timestamp_message('After  setting up space for observations')
call     trace_message('After  setting up space for observations')

call trace_message('Before setting up space for ensembles')

! Allocate model size storage and ens_size storage for metadata for outputting ensembles
model_size = get_model_size()

! set up ensemble HK WATCH OUT putting this here.
if(distributed_state) then
   call init_ensemble_manager(state_ens_handle, ens_size + num_extras, model_size)
else
   call init_ensemble_manager(state_ens_handle, ens_size + num_extras, model_size, transpose_type_in = 2)
endif
call set_num_extra_copies(state_ens_handle, num_extras)

call trace_message('After  setting up space for ensembles')

! Don't currently support number of processes > model_size
if(task_count() > model_size) call error_handler(E_ERR,'filter_main', &
   'Number of processes > model size' ,source,revision,revdate)

call     trace_message('Before reading in ensemble restart files')
call timestamp_message('Before reading in ensemble restart files')

! Set a time type for initial time if namelist inputs are not negative
call filter_set_initial_time(init_time_days, init_time_seconds, time1, read_time_from_file)

! set up arrays for which copies to read/write
call setup_read_write(ens_size + num_extras)

! Read in restart files and initialize the ensemble storage
call turn_read_copy_on(1, ens_size) ! need to read all restart copies

! allocating storage space in ensemble manager
!  - should this be in ensemble_manager
if(.not. direct_netcdf_read .and. .not. get_allow_transpose(state_ens_handle) ) allocate(state_ens_handle%vars(state_ens_handle%num_vars, state_ens_handle%my_num_copies))

! Moved this. Not doing anything with it, but when we do it should be before the read
! Read in or initialize smoother restarts as needed
if(ds) then
   call init_smoother(state_ens_handle, POST_INF_COPY, POST_INF_SD_COPY)
   call smoother_read_restart(state_ens_handle, ens_size, model_size, time1, init_time_days)
endif

! Initialize the adaptive inflation module
! This activates turn_read_copy_on or reads inflation for regular dart restarts
call adaptive_inflate_init(prior_inflate, inf_flavor(1), inf_initial_from_restart(1), &
   inf_sd_initial_from_restart(1), inf_output_restart(1), inf_deterministic(1),       &
   inf_in_file_name(1), inf_out_file_name(1), inf_diag_file_name(1), inf_initial(1),  &
   inf_sd_initial(1), inf_lower_bound(1), inf_upper_bound(1), inf_sd_lower_bound(1),  &
   state_ens_handle, PRIOR_INF_COPY, PRIOR_INF_SD_COPY, allow_missing, 'Prior',             &
   direct_netcdf_read)

call adaptive_inflate_init(post_inflate, inf_flavor(2), inf_initial_from_restart(2),  &
   inf_sd_initial_from_restart(2), inf_output_restart(2), inf_deterministic(2),       &
   inf_in_file_name(2), inf_out_file_name(2), inf_diag_file_name(2), inf_initial(2),  &
   inf_sd_initial(2), inf_lower_bound(2), inf_upper_bound(2), inf_sd_lower_bound(2),  &
   state_ens_handle, POST_INF_COPY, POST_INF_SD_COPY, allow_missing, 'Posterior',           &
   direct_netcdf_read)


if (do_output()) then
   if (inf_flavor(1) > 0 .and. inf_damping(1) < 1.0_r8) then
      write(msgstring, '(A,F12.6,A)') 'Prior inflation damping of ', inf_damping(1), ' will be used'
      call error_handler(E_MSG,'filter:', msgstring)
   endif
   if (inf_flavor(2) > 0 .and. inf_damping(2) < 1.0_r8) then
      write(msgstring, '(A,F12.6,A)') 'Posterior inflation damping of ', inf_damping(2), ' will be used'
      call error_handler(E_MSG,'filter:', msgstring)
   endif
endif

call trace_message('After  initializing inflation')


! HK Moved initializing inflation to before read of netcdf restarts so you can read the restarts
! and inflation files in one step.
if (.not. direct_netcdf_read ) then ! expecting DART restart files
   call filter_read_restart(state_ens_handle, time1)
   call all_vars_to_all_copies(state_ens_handle)
   ! deallocate whole state storage - should this be in ensemble_manager?
   if (.not. get_allow_transpose(state_ens_handle))deallocate(state_ens_handle%vars)
endif

call set_filenames(state_ens_handle, state_ens_handle%num_copies - num_extras, inf_in_file_name, inf_out_file_name)

if (direct_netcdf_read) then
   call filter_read_restart_direct(state_ens_handle, time1, num_extras, read_time_from_file )
   call get_minmax_task_zero_distrib(prior_inflate, state_ens_handle, PRIOR_INF_COPY, PRIOR_INF_SD_COPY)
   call log_inflation_info(prior_inflate, 'Prior')
   call get_minmax_task_zero_distrib(post_inflate, state_ens_handle, POST_INF_COPY, POST_INF_SD_COPY)
   call log_inflation_info(post_inflate, 'Posterior')
endif
         
if (perturb_restarts) then
! perturb the state if requested. This assumes that all of the ensemble members exist.
   if (perturb_bitwise) then
      if(.not. get_allow_transpose(state_ens_handle)) allocate(state_ens_handle%vars(state_ens_handle%num_vars, state_ens_handle%my_num_copies))
      call all_copies_to_all_vars(state_ens_handle)
      do i = 1, state_ens_handle%my_num_copies 
         !>@todo if interface is not provided then you have to loop over
         !> the copies and perturb yourself
         call pert_model_state(state_ens_handle%vars(:, i), &
                               state_ens_handle%vars(:, i), interf_provided)
         if (.not. interf_provided ) then
            call error_handler(E_ERR, 'filter', 'must have a pert_model_state routine for bitwise perturb test')

         endif
      enddo
      call all_vars_to_all_copies(state_ens_handle)
      if(.not. get_allow_transpose(state_ens_handle)) deallocate(state_ens_handle%vars)
   else
      call perturb_copies(state_ens_handle, perturbation_amplitude)
   endif
endif


!call test_state_copies(state_ens_handle, 'after_read')
!goto 10011

call timestamp_message('After  reading in ensemble restart files')
call     trace_message('After  reading in ensemble restart files')

! see what our stance is on missing values in the state vector
allow_missing = get_missing_ok_status()

call trace_message('Before initializing inflation')


call     trace_message('Before initializing output files')
call timestamp_message('Before initializing output files')

! Initialize the output sequences and state files and set their meta data
! Is there a problem if every task creates the meta data?
call filter_generate_copy_meta_data(seq, prior_inflate, &
      PriorStateUnit, PosteriorStateUnit, in_obs_copy, output_state_mean_index, &
      output_state_spread_index, prior_obs_mean_index, posterior_obs_mean_index, &
      prior_obs_spread_index, posterior_obs_spread_index)

if(ds) call error_handler(E_ERR, 'filter', 'smoother broken by Helen')
if(ds) call smoother_gen_copy_meta_data(num_output_state_members, output_inflation=.true.) !> @todo fudge

call timestamp_message('After  initializing output files')
call     trace_message('After  initializing output files')

call trace_message('Before trimming obs seq if start/stop time specified')

! Need to find first obs with appropriate time, delete all earlier ones
if(first_obs_seconds > 0 .or. first_obs_days > 0) then
   first_obs_time = set_time(first_obs_seconds, first_obs_days)
   call delete_seq_head(first_obs_time, seq, all_gone)
   if(all_gone) then
      msgstring = 'All obs in sequence are before first_obs_days:first_obs_seconds'
      call error_handler(E_ERR,'filter_main',msgstring,source,revision,revdate)
   endif
endif

! Start assimilating at beginning of modified sequence
last_key_used = -99

! Also get rid of observations past the last_obs_time if requested
if(last_obs_seconds >= 0 .or. last_obs_days >= 0) then
   last_obs_time = set_time(last_obs_seconds, last_obs_days)
   call delete_seq_tail(last_obs_time, seq, all_gone)
   if(all_gone) then
      msgstring = 'All obs in sequence are after last_obs_days:last_obs_seconds'
      call error_handler(E_ERR,'filter_main',msgstring,source,revision,revdate)
   endif
endif

call trace_message('After  trimming obs seq if start/stop time specified')

! Time step number is used to do periodic diagnostic output
time_step_number = -1
curr_ens_time = set_time(0, 0)
next_ens_time = set_time(0, 0)
call filter_set_window_time(window_time)

AdvanceTime : do
   call trace_message('Top of main advance time loop')

   time_step_number = time_step_number + 1
   write(msgstring , '(A,I5)') &
      'Main assimilation loop, starting iteration', time_step_number
   call trace_message(' ', ' ', -1)
   call trace_message(msgstring, 'filter: ', -1)

   ! Check the time before doing the first model advance.  Not all tasks
   ! might have a time, so only check on PE0 if running multitask.
   ! This will get broadcast (along with the post-advance time) to all
   ! tasks so everyone has the same times, whether they have copies or not.
   ! If smoothing, we need to know whether the move_ahead actually advanced
   ! the model or not -- the first time through this loop the data timestamp
   ! may already include the first observation, and the model will not need
   ! to be run.  Also, last time through this loop, the move_ahead call
   ! will determine if there are no more obs, not call the model, and return
   ! with no keys in the list, which is how we know to exit.  In both of
   ! these cases, we must not advance the times on the lags.

   ! Figure out how far model needs to move data to make the window
   ! include the next available observation.  recent change is 
   ! curr_ens_time in move_ahead() is intent(inout) and doesn't get changed 
   ! even if there are no more obs.
   call trace_message('Before move_ahead checks time of data and next obs')

   call move_ahead(state_ens_handle, ens_size, seq, last_key_used, window_time, &
      key_bounds, num_obs_in_set, curr_ens_time, next_ens_time)

   call trace_message('After  move_ahead checks time of data and next obs')

   ! Only processes with an ensemble copy know to exit;
   ! For now, let process 0 broadcast its value of key_bounds
   ! This will synch the loop here and allow everybody to exit
   ! Need to clean up and have a broadcast that just sends a single integer???
   ! PAR For now, can only broadcast real arrays
   call filter_sync_keys_time(state_ens_handle, key_bounds, num_obs_in_set, curr_ens_time, next_ens_time)
   if(key_bounds(1) < 0) then 
      call trace_message('No more obs to assimilate, exiting main loop', 'filter:', -1)
      exit AdvanceTime
   endif


   ! if model state data not at required time, advance model
   if (curr_ens_time /= next_ens_time) then
      ! Advance the lagged distribution, if needed.
      ! Must be done before the model runs and updates the data.
      if(ds) then
         call     trace_message('Before advancing smoother')
         call timestamp_message('Before advancing smoother')
         call advance_smoother(state_ens_handle)
         call timestamp_message('After  advancing smoother')
         call     trace_message('After  advancing smoother')
      endif

      call trace_message('Ready to run model to advance data ahead in time', 'filter:', -1)
      call print_ens_time(state_ens_handle, 'Ensemble data time before advance')
      call     trace_message('Before running model')
      call timestamp_message('Before running model', sync=.true.)

      ! allocating storage space in ensemble manager
      if(.not. allocated(state_ens_handle%vars)) allocate(state_ens_handle%vars(state_ens_handle%num_vars, state_ens_handle%my_num_copies))
      call all_copies_to_all_vars(state_ens_handle)

      call advance_state(state_ens_handle, ens_size, next_ens_time, async, &
                         adv_ens_command, tasks_per_model_advance)

      call all_vars_to_all_copies(state_ens_handle)
      ! deallocate whole state storage
      if(.not. get_allow_transpose(state_ens_handle)) deallocate(state_ens_handle%vars)

      ! update so curr time is accurate.
      curr_ens_time = next_ens_time

      ! only need to sync here since we want to wait for the
      ! slowest task to finish before outputting the time.
      call timestamp_message('After  running model', sync=.true.)
      call     trace_message('After  running model')
      call print_ens_time(state_ens_handle, 'Ensemble data time after  advance')
   else
      call trace_message('Model does not need to run; data already at required time', 'filter:', -1)
   endif

   call trace_message('Before setup for next group of observations')
   write(msgstring, '(A,I7)') 'Number of observations to be assimilated', &
      num_obs_in_set
   call trace_message(msgstring)
   call print_obs_time(seq, key_bounds(1), 'Time of first observation in window')
   call print_obs_time(seq, key_bounds(2), 'Time of last  observation in window')

   ! Create an ensemble for the observations from this time plus
   ! obs_error_variance, observed value, key from sequence, global qc, 
   ! then mean for each group, then variance for each group
   call init_ensemble_manager(obs_fwd_op_ens_handle, TOTAL_OBS_COPIES, int(num_obs_in_set,i8), 1, transpose_type_in = 2)
   ! Also need a qc field for copy of each observation
   call init_ensemble_manager(qc_ens_handle, ens_size, int(num_obs_in_set,i8), 1, transpose_type_in = 2)

   ! Allocate storage for the keys for this number of observations
   allocate(keys(num_obs_in_set)) ! This is still var size for writing out the observation sequence

   ! Get all the keys associated with this set of observations
   ! Is there a way to distribute this?
   call get_time_range_keys(seq, key_bounds, num_obs_in_set, keys)

   call trace_message('After  setup for next group of observations')

   ! Compute mean and spread for inflation and state diagnostics
   call compute_copy_mean_sd(state_ens_handle, 1, ens_size, ENS_MEAN_COPY, ENS_SD_COPY)

   if(do_single_ss_inflate(prior_inflate) .or. do_varying_ss_inflate(prior_inflate)) then
      call trace_message('Before prior inflation damping and prep')
      !call test_state_copies(state_ens_handle, 'before_prior_inflation')

      if (inf_damping(1) /= 1.0_r8) then
         call prepare_to_update_copies(state_ens_handle)
         state_ens_handle%copies(PRIOR_INF_COPY, :) = 1.0_r8 + &
            inf_damping(1) * (state_ens_handle%copies(PRIOR_INF_COPY, :) - 1.0_r8) 
      endif

      call filter_ensemble_inflate(state_ens_handle, PRIOR_INF_COPY, prior_inflate, ENS_MEAN_COPY)

      !call test_state_copies(state_ens_handle, 'after_prior_inflation')

      ! Recompute the the mean and spread as required for diagnostics
      call compute_copy_mean_sd(state_ens_handle, 1, ens_size, ENS_MEAN_COPY, ENS_SD_COPY)

      call trace_message('After  prior inflation damping and prep')
   endif

   call     trace_message('Before computing prior observation values')
   call timestamp_message('Before computing prior observation values')

   ! Compute the ensemble of prior observations, load up the obs_err_var
   ! and obs_values. ens_size is the number of regular ensemble members,
   ! not the number of copies
   !start = MPI_WTIME()

   ! allocate() space for the prior qc copy
   call allocate_single_copy(obs_fwd_op_ens_handle, prior_qc_copy)

   call get_obs_ens_distrib_state(state_ens_handle, obs_fwd_op_ens_handle, qc_ens_handle, &
     seq, keys, obs_val_index, input_qc_index, &
     OBS_ERR_VAR_COPY, OBS_VAL_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY, OBS_EXTRA_QC_COPY, &
     OBS_MEAN_START, OBS_VAR_START, isprior=.true., prior_qc_copy=prior_qc_copy)

   !finish = MPI_WTIME()

   !if (my_task_id() == 0) print*, 'distributed average ', (finish-start)
   !call test_obs_copies(obs_fwd_op_ens_handle, 'prior')

   !goto 10011 !HK bail out after forward operators

   ! While we're here, make sure the timestamp on the extra ensemble copies
   ! have the current time.  If the user requests it be written out, it needs 
   ! a valid timestamp.
   if (my_task_id() == 0 ) print*, '************ MEAN TIME *****************'
   call set_copy_time(state_ens_handle, ENS_MEAN_COPY,     curr_ens_time)
   call set_copy_time(state_ens_handle, ENS_SD_COPY,       curr_ens_time)
   call set_copy_time(state_ens_handle, PRIOR_INF_COPY,    curr_ens_time)
   call set_copy_time(state_ens_handle, PRIOR_INF_SD_COPY, curr_ens_time)
   call set_copy_time(state_ens_handle, POST_INF_COPY,     curr_ens_time)
   call set_copy_time(state_ens_handle, POST_INF_SD_COPY,  curr_ens_time)

   if (spare_copies) then
      call set_copy_time(state_ens_handle, SPARE_COPY_MEAN,       curr_ens_time)
      call set_copy_time(state_ens_handle, SPARE_COPY_SPREAD,     curr_ens_time)
      call set_copy_time(state_ens_handle, SPARE_COPY_INF_MEAN,   curr_ens_time)
      call set_copy_time(state_ens_handle, SPARE_COPY_INF_SPREAD, curr_ens_time)
   endif

   call timestamp_message('After  computing prior observation values')
   call     trace_message('After  computing prior observation values')

   ! Do prior state space diagnostic output as required

!!*********************
! Diagnostic files.

   call trace_message('Before prior state space diagnostics')
   call timestamp_message('Before prior state space diagnostics')

   ! Store inflation mean copy in the spare copy. 
   ! The spare copy is left alone until the end
   ! shoving in four spare copies for now
   if (spare_copies) then ! need to store prior copies until the end
                                                       ! Note this is just for single time step runs
      state_ens_handle%copies(SPARE_COPY_MEAN, :)       = state_ens_handle%copies(ENS_MEAN_COPY, :)
      state_ens_handle%copies(SPARE_COPY_SPREAD, :)     = state_ens_handle%copies(ENS_SD_COPY, :)
      state_ens_handle%copies(SPARE_COPY_INF_MEAN, :)   = state_ens_handle%copies(PRIOR_INF_COPY, :)
      state_ens_handle%copies(SPARE_COPY_INF_SPREAD, :) = state_ens_handle%copies(PRIOR_INF_SD_COPY, :)
   endif

   if ((output_interval > 0) .and. &
       (time_step_number / output_interval * output_interval == time_step_number)) then

      if(diagnostic_files) then
         ! Diagnostic files
         call filter_state_space_diagnostics(curr_ens_time, PriorStateUnit, state_ens_handle, &
            model_size, num_output_state_members, &
            output_state_mean_index, output_state_spread_index, output_inflation,&
            ENS_MEAN_COPY, ENS_SD_COPY, &
            prior_inflate, PRIOR_INF_COPY, PRIOR_INF_SD_COPY)

      else ! only write output members as netcdf if you are not writing diagnostic files

         ! write prior files if you have ensemble members to output
         if (.not. spare_copies) then
            call turn_write_copy_off(1, ens_size + num_extras) ! clean slate
            call turn_write_copy_on(1, num_output_state_members)
            ! need to ouput the diagnostic info in restart files
               call turn_write_copy_on(ENS_MEAN_COPY)
               call turn_write_copy_on(ENS_SD_COPY)
               if (output_inflation) then
                  call turn_write_copy_on(PRIOR_INF_COPY)
                  call turn_write_copy_on(PRIOR_INF_SD_COPY)
               endif
            !FIXME - what to do with lorenz_96 (or similar) here?
            call filter_write_restart_direct(state_ens_handle, num_extras, isprior = .true.)
         endif

      endif

   endif

   call timestamp_message('After  prior state space diagnostics')
   call trace_message('After  prior state space diagnostics')

   call trace_message('Before observation space diagnostics')

   ! This is where the mean obs
   ! copy ( + others ) is moved to task 0 so task 0 can update seq.
   ! There is a transpose (all_copies_to_all_vars(obs_fwd_op_ens_handle)) in obs_space_diagnostics
   ! Do prior observation space diagnostics and associated quality control
   call obs_space_diagnostics(obs_fwd_op_ens_handle, qc_ens_handle, ens_size, &
      seq, keys, PRIOR_DIAG, num_output_obs_members, in_obs_copy+1, &
      obs_val_index, OBS_KEY_COPY, &                                 ! new
      prior_obs_mean_index, prior_obs_spread_index, num_obs_in_set, &
      OBS_MEAN_START, OBS_VAR_START, OBS_GLOBAL_QC_COPY, &
      OBS_VAL_COPY, OBS_ERR_VAR_COPY, DART_qc_index)
   call trace_message('After  observation space diagnostics')


!*********************

   ! FIXME:  i believe both copies and vars are equal at the end
   ! of the obs_space diags, so we can skip this. 
   !call all_vars_to_all_copies(obs_fwd_op_ens_handle)

   write(msgstring, '(A,I8,A)') 'Ready to assimilate up to', size(keys), ' observations'
   call trace_message(msgstring, 'filter:', -1)

   call     trace_message('Before observation assimilation')
   call timestamp_message('Before observation assimilation')

   !call test_state_copies(state_ens_handle, 'before_filter_assim')

   call filter_assim(state_ens_handle, obs_fwd_op_ens_handle, seq, keys, &
      ens_size, num_groups, obs_val_index, prior_inflate, &
      ENS_MEAN_COPY, ENS_SD_COPY, &
      PRIOR_INF_COPY, PRIOR_INF_SD_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY, &
      OBS_MEAN_START, OBS_MEAN_END, OBS_VAR_START, &
      OBS_VAR_END, inflate_only = .false.)

   !call test_state_copies(state_ens_handle, 'after_filter_assim')

   call timestamp_message('After  observation assimilation')
   call     trace_message('After  observation assimilation')

   ! Do the update for the smoother lagged fields, too.
   ! Would be more efficient to do these all at once inside filter_assim 
   ! in the future
   if(ds) then
      write(msgstring, '(A,I8,A)') 'Ready to reassimilate up to', size(keys), ' observations in the smoother'
      call trace_message(msgstring, 'filter:', -1)

      call     trace_message('Before smoother assimilation')
      call timestamp_message('Before smoother assimilation')
      call smoother_assim(obs_fwd_op_ens_handle, seq, keys, ens_size, num_groups, &
         obs_val_index, ENS_MEAN_COPY, ENS_SD_COPY, &
         PRIOR_INF_COPY, PRIOR_INF_SD_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY, &
         OBS_MEAN_START, OBS_MEAN_END, OBS_VAR_START, &
         OBS_VAR_END)
      call timestamp_message('After  smoother assimilation')
      call     trace_message('After  smoother assimilation')
   endif

   ! Already transformed, so compute mean and spread for state diag as needed
   call compute_copy_mean_sd(state_ens_handle, 1, ens_size, ENS_MEAN_COPY, ENS_SD_COPY)

!-------- Test of posterior inflate ----------------

   if(do_single_ss_inflate(post_inflate) .or. do_varying_ss_inflate(post_inflate)) then

      call trace_message('Before posterior inflation damping and prep')
      !call test_state_copies(state_ens_handle, 'before_test_of_inflation')

      if (inf_damping(2) /= 1.0_r8) then
         call prepare_to_update_copies(state_ens_handle)
         state_ens_handle%copies(POST_INF_COPY, :) = 1.0_r8 + &
            inf_damping(2) * (state_ens_handle%copies(POST_INF_COPY, :) - 1.0_r8) 
      endif

    call filter_ensemble_inflate(state_ens_handle, POST_INF_COPY, post_inflate, ENS_MEAN_COPY)

    !call test_state_copies(state_ens_handle, 'after_test_of_inflation')

      ! Recompute the mean or the mean and spread as required for diagnostics
      call compute_copy_mean_sd(state_ens_handle, 1, ens_size, ENS_MEAN_COPY, ENS_SD_COPY)

      call trace_message('After  posterior inflation damping and prep')
   endif

!-------- End of posterior  inflate ----------------


   call     trace_message('Before computing posterior observation values')
   call timestamp_message('Before computing posterior observation values')

   ! Compute the ensemble of posterior observations, load up the obs_err_var 
   ! and obs_values.  ens_size is the number of regular ensemble members, 
   ! not the number of copies

    call get_obs_ens_distrib_state(state_ens_handle, obs_fwd_op_ens_handle, qc_ens_handle, &
     seq, keys, obs_val_index, input_qc_index, &
     OBS_ERR_VAR_COPY, OBS_VAL_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY, OBS_EXTRA_QC_COPY, &
     OBS_MEAN_START, OBS_VAR_START, isprior=.false., prior_qc_copy=prior_qc_copy)

   !call test_obs_copies(obs_fwd_op_ens_handle, 'post')
   call deallocate_single_copy(obs_fwd_op_ens_handle, prior_qc_copy)

   call timestamp_message('After  computing posterior observation values')
   call     trace_message('After  computing posterior observation values')

   if(ds) then
      call trace_message('Before computing smoother means/spread')
      call smoother_mean_spread(ens_size, ENS_MEAN_COPY, ENS_SD_COPY)
      call trace_message('After  computing smoother means/spread')
   endif

!***********************
!! Diagnostic files.

   call trace_message('Before posterior state space diagnostics')
   call timestamp_message('Before posterior state space diagnostics')

   ! Do posterior state space diagnostic output as required
   if ((output_interval > 0) .and. &
         (time_step_number / output_interval * output_interval == time_step_number)) then

      if (diagnostic_files) then
         ! skeleton just to put time in the diagnostic file
         call filter_state_space_diagnostics(curr_ens_time, PosteriorStateUnit, state_ens_handle, &
            model_size, num_output_state_members, output_state_mean_index, &
            output_state_spread_index, output_inflation, &
            ENS_MEAN_COPY, ENS_SD_COPY, &
            post_inflate, POST_INF_COPY, POST_INF_SD_COPY)
         ! Cyclic storage for lags with most recent pointed to by smoother_head
         ! ens_mean is passed to avoid extra temp storage in diagnostics

         !> @todo What to do here?
         !call smoother_ss_diagnostics(model_size, num_output_state_members, &
         !  output_inflation, temp_ens, ENS_MEAN_COPY, ENS_SD_COPY, &
         ! POST_INF_COPY, POST_INF_SD_COPY)
      endif
   endif

   call timestamp_message('After  posterior state space diagnostics')
   call trace_message('After  posterior state space diagnostics')

   call trace_message('Before posterior obs space diagnostics')

   ! Do posterior observation space diagnostics
   ! There is a transpose (all_copies_to_all_vars(obs_fwd_op_ens_handle)) in obs_space_diagnostics
   call obs_space_diagnostics(obs_fwd_op_ens_handle, qc_ens_handle, ens_size, &
      seq, keys, POSTERIOR_DIAG, num_output_obs_members, in_obs_copy+2, &
      obs_val_index, OBS_KEY_COPY, &                             ! new
      posterior_obs_mean_index, posterior_obs_spread_index, num_obs_in_set, &
      OBS_MEAN_START, OBS_VAR_START, OBS_GLOBAL_QC_COPY, &
      OBS_VAL_COPY, OBS_ERR_VAR_COPY, DART_qc_index)

!***********************

   call trace_message('After  posterior obs space diagnostics')

!-------- Test of posterior inflate ----------------
 
   if(do_single_ss_inflate(post_inflate) .or. do_varying_ss_inflate(post_inflate)) then

      ! If not reading the sd values from a restart file and the namelist initial
      !  sd < 0, then bypass this entire code block altogether for speed.
      if ((inf_sd_initial(2) >= 0.0_r8) .or. inf_sd_initial_from_restart(2)) then

         call     trace_message('Before computing posterior state space inflation')
         call timestamp_message('Before computing posterior state space inflation')

         call filter_assim(state_ens_handle, obs_fwd_op_ens_handle, seq, keys, ens_size, num_groups, &
            obs_val_index, post_inflate, ENS_MEAN_COPY, ENS_SD_COPY, &
            POST_INF_COPY, POST_INF_SD_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY, &
            OBS_MEAN_START, OBS_MEAN_END, OBS_VAR_START, &
            OBS_VAR_END, inflate_only = .true.)

         call timestamp_message('After  computing posterior state space inflation')
         call     trace_message('After  computing posterior state space inflation')

      endif  ! sd >= 0 or sd from restart file
   endif  ! if doing state space posterior inflate


!-------- End of posterior  inflate ----------------

   ! If observation space inflation, output the diagnostics
   if(do_obs_inflate(prior_inflate) .and. my_task_id() == 0) &
      call output_inflate_diagnostics(prior_inflate, curr_ens_time)

   call trace_message('Near bottom of main loop, cleaning up obs space')
   ! Deallocate storage used for keys for each set
   deallocate(keys)

   ! The last key used is updated to move forward in the observation sequence
   last_key_used = key_bounds(2)

   ! Free up the obs ensemble space; LATER, can just keep it if obs are same size next time
   call end_ensemble_manager(obs_fwd_op_ens_handle)
   call end_ensemble_manager(qc_ens_handle)

   call trace_message('Bottom of main advance time loop')
end do AdvanceTime

!call test_state_copies(state_ens_handle, 'last')

!10011 continue

call trace_message('End of main filter assimilation loop, starting cleanup', 'filter:', -1)

call trace_message('Before finalizing diagnostics files')
! properly dispose of the diagnostics files
if(my_task_id() == 0 .and. diagnostic_files) then
   ierr = finalize_diag_output(PriorStateUnit)
   ierr = finalize_diag_output(PosteriorStateUnit)
endif
call trace_message('After  finalizing diagnostics files')

call trace_message('Before writing output sequence file')
! Only pe 0 outputs the observation space diagnostic file
if(my_task_id() == 0) call write_obs_seq(seq, obs_sequence_out_name)
call trace_message('After  writing output sequence file')

call trace_message('Before writing inflation restart files if required')
call turn_write_copy_off(1, ens_size + num_extras) ! clean slate

! Output the restart for the adaptive inflation parameters
if (.not. direct_netcdf_write ) then
   ! allocating storage space in ensemble manager
   !  - should this be in ensemble_manager?
   if (.not. get_allow_transpose(state_ens_handle)) allocate(state_ens_handle%vars(state_ens_handle%num_vars, state_ens_handle%my_num_copies))
   call all_copies_to_all_vars(state_ens_handle)
endif

call adaptive_inflate_end(prior_inflate, state_ens_handle, PRIOR_INF_COPY, PRIOR_INF_SD_COPY, direct_netcdf_write)
call adaptive_inflate_end(post_inflate, state_ens_handle, POST_INF_COPY, POST_INF_SD_COPY, direct_netcdf_write)
call trace_message('After  writing inflation restart files if required')

! Output a restart file if requested
call trace_message('Before writing state restart files if requested')
call timestamp_message('Before writing state restart files if requested')

if (output_restart)      call turn_write_copy_on(1,ens_size) ! restarts
if (output_restart_mean) call turn_write_copy_on(ENS_MEAN_COPY)

! Prior_Diag copies - write spare copies
! But don't bother writing if you are writing diagnostic files.
if (spare_copies) then
   call turn_write_copy_on(SPARE_COPY_MEAN)
   call turn_write_copy_on(SPARE_COPY_SPREAD)
   if (output_inflation) then
      call turn_write_copy_on(SPARE_COPY_INF_MEAN)
      call turn_write_copy_on(SPARE_COPY_INF_SPREAD)
   endif
endif

! Posterior Diag 
call turn_write_copy_on(ENS_MEAN_COPY) ! mean
call turn_write_copy_on(ENS_SD_COPY) ! sd
if (output_inflation) then
   call turn_write_copy_on(POST_INF_COPY)
   call turn_write_copy_on(POST_INF_SD_COPY)
endif

if(direct_netcdf_write) then
   call filter_write_restart_direct(state_ens_handle, num_extras, isprior=.false.)
else ! write binary files
   if(output_restart) call write_ensemble_restart(state_ens_handle, restart_out_file_name, 1, ens_size)
   if(output_restart_mean) call write_ensemble_restart(state_ens_handle, trim(restart_out_file_name)//'.mean', &
                                  ENS_MEAN_COPY, ENS_MEAN_COPY, .true.)
endif

! deallocate whole state storage - should this be in ensemble_manager
if (.not. direct_netcdf_write) deallocate(state_ens_handle%vars)

if(ds) call smoother_write_restart(1, ens_size)
call trace_message('After  writing state restart files if requested')
call timestamp_message('After  writing state restart files if requested')

! Give the model_mod code a chance to clean up. 
call trace_message('Before end_model call')
call end_assim_model()
call trace_message('After  end_model call')

call trace_message('Before ensemble and obs memory cleanup')
call end_ensemble_manager(state_ens_handle)

! Free up the observation kind and obs sequence
call destroy_obs(observation)
call destroy_obs_sequence(seq)
call trace_message('After  ensemble and obs memory cleanup')

if(ds) then 
   call trace_message('Before smoother memory cleanup')
   call smoother_end()
   call trace_message('After  smoother memory cleanup')
endif

call     trace_message('Filter done')
call timestamp_message('Filter done')
if(my_task_id() == 0) then 
   write(logfileunit,*)'FINISHED filter.'
   write(logfileunit,*)
endif

10011 continue
! YOU CAN NO LONGER WRITE TO THE LOG FILE BELOW THIS!
! After the call to finalize below, you cannot write to
! any fortran unit number.

! Make this the very last thing done, especially for SGI systems.
! It shuts down MPI and if you try to write after that, some libraries
! choose to discard output that is written after mpi is finalized, or 
! worse, the processes can hang.
call finalize_mpi_utilities(async=async)

end subroutine filter_main

!-----------------------------------------------------------

subroutine filter_generate_copy_meta_data(seq, prior_inflate, PriorStateUnit, &
   PosteriorStateUnit, in_obs_copy, output_state_mean_index, &
   output_state_spread_index, prior_obs_mean_index, posterior_obs_mean_index, &
   prior_obs_spread_index, posterior_obs_spread_index)

type(obs_sequence_type),     intent(inout) :: seq
type(adaptive_inflate_type), intent(in)    :: prior_inflate
type(netcdf_file_type),      intent(inout) :: PriorStateUnit, PosteriorStateUnit
integer,                     intent(out)   :: output_state_mean_index, output_state_spread_index
integer,                     intent(in)    :: in_obs_copy
integer,                     intent(out)   :: prior_obs_mean_index, posterior_obs_mean_index
integer,                     intent(out)   :: prior_obs_spread_index, posterior_obs_spread_index

! Figures out the strings describing the output copies for the three output files.
! THese are the prior and posterior state output files and the observation sequence
! output file which contains both prior and posterior data.

character(len=metadatalength) :: prior_meta_data, posterior_meta_data
! The 4 is for ensemble mean and spread plus inflation mean and spread
! The Prior file contains the prior inflation mean and spread only
! Posterior file contains the posterior inflation mean and spread only
character(len=metadatalength) :: state_meta(num_output_state_members + 4)
integer :: i, ensemble_offset, num_state_copies, num_obs_copies
integer :: ierr ! init_diag return code

! Section for state variables + other generated data stored with them.

! Ensemble mean goes first 
num_state_copies = num_output_state_members + 2
output_state_mean_index = 1
state_meta(output_state_mean_index) = 'ensemble mean'

! Ensemble spread goes second
output_state_spread_index = 2
state_meta(output_state_spread_index) = 'ensemble spread'

! Check for too many output ensemble members
if(num_output_state_members > 10000) then
   write(msgstring, *)'output metadata in filter needs state ensemble size < 10000, not ', &
                      num_output_state_members
   call error_handler(E_ERR,'filter_generate_copy_meta_data',msgstring,source,revision,revdate)
endif

! Compute starting point for ensemble member output
ensemble_offset = 2

! Set up the metadata for the output state diagnostic files
do i = 1, num_output_state_members
   write(state_meta(i + ensemble_offset), '(a15, 1x, i6)') 'ensemble member', i
end do

! Next two slots are for inflation mean and sd metadata
! To avoid writing out inflation values to the Prior and Posterior netcdf files,
! set output_inflation to false in the filter section of input.nml 
!> @todo fudge
!f(output_inflation) then
   num_state_copies = num_state_copies + 2
   state_meta(num_state_copies-1) = 'inflation mean'
   state_meta(num_state_copies)   = 'inflation sd'
!endif

! Have task 0 set up diagnostic output for model state, if output is desired
! I am not using a collective call here, just getting task 0 to set up the files
! - nc_write_model_atts.
if (my_task_id() == 0 .and. diagnostic_files) then
   PriorStateUnit     = init_diag_output('Prior_Diag', &
                        'prior ensemble state', num_state_copies, state_meta)
   PosteriorStateUnit = init_diag_output('Posterior_Diag', &
                        'posterior ensemble state', num_state_copies, state_meta)
endif

! Set the metadata for the observations.

! Set up obs ensemble mean
num_obs_copies = in_obs_copy
num_obs_copies = num_obs_copies + 1
prior_meta_data = 'prior ensemble mean'
call set_copy_meta_data(seq, num_obs_copies, prior_meta_data)
prior_obs_mean_index = num_obs_copies
num_obs_copies = num_obs_copies + 1
posterior_meta_data = 'posterior ensemble mean'
call set_copy_meta_data(seq, num_obs_copies, posterior_meta_data)
posterior_obs_mean_index = num_obs_copies 

! Set up obs ensemble spread 
num_obs_copies = num_obs_copies + 1
prior_meta_data = 'prior ensemble spread'
call set_copy_meta_data(seq, num_obs_copies, prior_meta_data)
prior_obs_spread_index = num_obs_copies
num_obs_copies = num_obs_copies + 1
posterior_meta_data = 'posterior ensemble spread'
call set_copy_meta_data(seq, num_obs_copies, posterior_meta_data)
posterior_obs_spread_index = num_obs_copies

! Make sure there are not too many copies requested
if(num_output_obs_members > 10000) then
   write(msgstring, *)'output metadata in filter needs obs ensemble size < 10000, not ',&
                      num_output_obs_members
   call error_handler(E_ERR,'filter_generate_copy_meta_data',msgstring,source,revision,revdate)
endif

! Set up obs ensemble members as requested
do i = 1, num_output_obs_members
   write(prior_meta_data, '(a21, 1x, i6)') 'prior ensemble member', i
   write(posterior_meta_data, '(a25, 1x, i6)') 'posterior ensemble member', i
   num_obs_copies = num_obs_copies + 1
   call set_copy_meta_data(seq, num_obs_copies, prior_meta_data)
   num_obs_copies = num_obs_copies + 1
   call set_copy_meta_data(seq, num_obs_copies, posterior_meta_data)
end do


end subroutine filter_generate_copy_meta_data

!-------------------------------------------------------------------------

subroutine filter_initialize_modules_used()

! Initialize modules used that require it
call initialize_mpi_utilities('Filter')

call register_module(source,revision,revdate)

! Initialize the obs sequence module
call static_init_obs_sequence()

! Initialize the model class data now that obs_sequence is all set up
call trace_message('Before init_model call')
call static_init_assim_model()
call trace_message('After  init_model call')
call static_init_state_type()
call trace_message('After  init_state_type call')
call io_filenames_init()
call state_vector_io_init()
call trace_message('After  init_state_vector_io call')
call initialize_qc()
call trace_message('After  initialize_qc call')

end subroutine filter_initialize_modules_used

!-------------------------------------------------------------------------

subroutine filter_setup_obs_sequence(seq, in_obs_copy, obs_val_index, &
   input_qc_index, DART_qc_index)

type(obs_sequence_type), intent(inout) :: seq
integer,                 intent(out)   :: in_obs_copy, obs_val_index
integer,                 intent(out)   :: input_qc_index, DART_qc_index

character(len = metadatalength) :: no_qc_meta_data = 'No incoming data QC'
character(len = metadatalength) :: dqc_meta_data   = 'DART quality control'
character(len = 129) :: obs_seq_read_format
integer              :: obs_seq_file_id, num_obs_copies
integer              :: tnum_copies, tnum_qc, tnum_obs, tmax_num_obs, qc_num_inc, num_qc
logical              :: pre_I_format

! Determine the number of output obs space fields
! 4 is for prior/posterior mean and spread, 
! Prior and posterior values for all selected fields (so times 2)
num_obs_copies = 2 * num_output_obs_members + 4

! Input file can have one qc field, none, or more.  note that read_obs_seq_header
! does NOT return the actual metadata values, which would be helpful in trying
! to decide if we need to add copies or qcs.
call read_obs_seq_header(obs_sequence_in_name, tnum_copies, tnum_qc, tnum_obs, tmax_num_obs, &
   obs_seq_file_id, obs_seq_read_format, pre_I_format, close_the_file = .true.)


! if there are less than 2 incoming qc fields, we will need
! to make at least 2 (one for the dummy data qc and one for
! the dart qc).
if (tnum_qc < 2) then
   qc_num_inc = 2 - tnum_qc
else
   qc_num_inc = 0
endif

! Read in with enough space for diagnostic output values and add'l qc field(s)
call read_obs_seq(obs_sequence_in_name, num_obs_copies, qc_num_inc, 0, seq)

! check to be sure that we have an incoming qc field.  if not, look for
! a blank qc field
input_qc_index = get_obs_qc_index(seq)
if (input_qc_index < 0) then
   input_qc_index = get_blank_qc_index(seq)
   if (input_qc_index < 0) then
      ! Need 1 new qc field for dummy incoming qc
      call add_qc(seq, 1)
      input_qc_index = get_blank_qc_index(seq)
      if (input_qc_index < 0) then
         call error_handler(E_ERR,'filter_setup_obs_sequence', &
           'error adding blank qc field to sequence; should not happen', &
            source, revision, revdate)
      endif
   endif
   ! Since we are constructing a dummy QC, label it as such
   call set_qc_meta_data(seq, input_qc_index, no_qc_meta_data)
endif

! check to be sure we either find an existing dart qc field and
! reuse it, or we add a new one.
DART_qc_index = get_obs_dartqc_index(seq)
if (DART_qc_index < 0) then
   DART_qc_index = get_blank_qc_index(seq)
   if (DART_qc_index < 0) then
      ! Need 1 new qc field for the DART quality control
      call add_qc(seq, 1)
      DART_qc_index = get_blank_qc_index(seq)
      if (DART_qc_index < 0) then
         call error_handler(E_ERR,'filter_setup_obs_sequence', &
           'error adding blank qc field to sequence; should not happen', &
            source, revision, revdate)
      endif
   endif
   call set_qc_meta_data(seq, DART_qc_index, dqc_meta_data)
endif

! Get num of obs copies and num_qc
num_qc = get_num_qc(seq)
in_obs_copy = get_num_copies(seq) - num_obs_copies

! Create an observation type temporary for use in filter
call init_obs(observation, get_num_copies(seq), num_qc)

! Set initial DART quality control to 0 for all observations?
! Or leave them uninitialized, since
! obs_space_diagnostics should set them all without reading them

! Determine which copy has actual obs
obs_val_index = get_obs_copy_index(seq)

end subroutine filter_setup_obs_sequence

!-------------------------------------------------------------------------

function get_obs_copy_index(seq)

type(obs_sequence_type), intent(in) :: seq
integer                             :: get_obs_copy_index

integer :: i

! Determine which copy in sequence has actual obs

do i = 1, get_num_copies(seq)
   get_obs_copy_index = i
   ! Need to look for 'observation'
   if(index(get_copy_meta_data(seq, i), 'observation') > 0) return
end do
! Falling of end means 'observations' not found; die
call error_handler(E_ERR,'get_obs_copy_index', &
   'Did not find observation copy with metadata "observation"', &
      source, revision, revdate)

end function get_obs_copy_index

!-------------------------------------------------------------------------

function get_obs_prior_index(seq)

type(obs_sequence_type), intent(in) :: seq
integer                             :: get_obs_prior_index

integer :: i

! Determine which copy in sequence has prior mean, if any.

do i = 1, get_num_copies(seq)
   get_obs_prior_index = i
   ! Need to look for 'prior mean'
   if(index(get_copy_meta_data(seq, i), 'prior ensemble mean') > 0) return
end do
! Falling of end means 'prior mean' not found; not fatal!

get_obs_prior_index = -1

end function get_obs_prior_index

!-------------------------------------------------------------------------

function get_obs_qc_index(seq)

type(obs_sequence_type), intent(in) :: seq
integer                             :: get_obs_qc_index

integer :: i

! Determine which qc, if any, has the incoming obs qc
! this is tricky because we have never specified what string
! the metadata has to have.  look for 'qc' or 'QC' and the
! first metadata that matches (much like 'observation' above)
! is the winner.

do i = 1, get_num_qc(seq)
   get_obs_qc_index = i

   ! Need to avoid 'QC metadata not initialized'
   if(index(get_qc_meta_data(seq, i), 'QC metadata not initialized') > 0) cycle
  
   ! Need to look for 'QC' or 'qc'
   if(index(get_qc_meta_data(seq, i), 'QC') > 0) return
   if(index(get_qc_meta_data(seq, i), 'qc') > 0) return
   if(index(get_qc_meta_data(seq, i), 'Quality Control') > 0) return
   if(index(get_qc_meta_data(seq, i), 'QUALITY CONTROL') > 0) return
end do
! Falling off end means 'QC' string not found; not fatal!

get_obs_qc_index = -1

end function get_obs_qc_index

!-------------------------------------------------------------------------

function get_obs_dartqc_index(seq)

type(obs_sequence_type), intent(in) :: seq
integer                             :: get_obs_dartqc_index

integer :: i

! Determine which qc, if any, has the DART qc

do i = 1, get_num_qc(seq)
   get_obs_dartqc_index = i
   ! Need to look for 'DART quality control'
   if(index(get_qc_meta_data(seq, i), 'DART quality control') > 0) return
end do
! Falling off end means 'DART quality control' not found; not fatal!

get_obs_dartqc_index = -1

end function get_obs_dartqc_index

!-------------------------------------------------------------------------

function get_blank_qc_index(seq)

type(obs_sequence_type), intent(in) :: seq
integer                             :: get_blank_qc_index

integer :: i

! Determine which qc, if any, is blank

do i = 1, get_num_qc(seq)
   get_blank_qc_index = i
   ! Need to look for 'QC metadata not initialized'
   if(index(get_qc_meta_data(seq, i), 'QC metadata not initialized') > 0) return
end do
! Falling off end means unused slot not found; not fatal!

get_blank_qc_index = -1

end function get_blank_qc_index

!-------------------------------------------------------------------------

subroutine filter_set_initial_time(days, seconds, time, read_time_from_file)

integer,         intent(in)  :: days, seconds
type(time_type), intent(out) :: time
logical,         intent(out) :: read_time_from_file

if(days >= 0) then
   time = set_time(seconds, days)
   read_time_from_file = .false.
else
   time = set_time(0, 0)
   read_time_from_file = .true.
endif

end subroutine filter_set_initial_time

!-------------------------------------------------------------------------

subroutine filter_set_window_time(time)

type(time_type), intent(out) :: time


if(obs_window_days >= 0) then
   time = set_time(obs_window_seconds, obs_window_days)
else
   time = set_time(0, 0)
endif

end subroutine filter_set_window_time

!-------------------------------------------------------------------------

subroutine filter_read_restart(state_ens_handle, time)

type(ensemble_type), intent(inout) :: state_ens_handle
type(time_type),     intent(inout) :: time

integer :: days, secs

if (do_output()) then
   if (start_from_restart) then
      call error_handler(E_MSG,'filter_read_restart:', &
         'Reading in initial condition/restart data for all ensemble members from file(s)')
   else
      call error_handler(E_MSG,'filter_read_restart:', &
         'Reading in a single ensemble and perturbing data for the other ensemble members')
   endif
endif

! Only read in initial conditions for actual ensemble members
if(init_time_days >= 0) then
   call read_ensemble_restart(state_ens_handle, 1, ens_size, &
      start_from_restart, restart_in_file_name, time)
   if (do_output()) then
      call get_time(time, secs, days)
      write(msgstring, '(A)') 'By namelist control, ignoring time found in restart file.'
      call error_handler(E_MSG,'filter_read_restart:',msgstring,source,revision,revdate)
      write(msgstring, '(A,I6,1X,I5)') 'Setting initial days, seconds to ',days,secs
      call error_handler(E_MSG,'filter_read_restart:',msgstring,source,revision,revdate)
   endif
else
   call read_ensemble_restart(state_ens_handle, 1, ens_size, &
      start_from_restart, restart_in_file_name)
      !> @todo time
   if (state_ens_handle%my_num_copies > 0) time = state_ens_handle%time(1)
endif

! Temporary print of initial model time
if(state_ens_handle%my_pe == 0) then
   ! FIXME for the future: if pe 0 is not task 0, pe 0 can not print debug messages
   call get_time(time, secs, days)
   write(msgstring, *) 'initial model time of 1st ensemble member (days,seconds) ',days,secs
   call error_handler(E_DBG,'filter_read_restart',msgstring,source,revision,revdate)
endif

end subroutine filter_read_restart

!-------------------------------------------------------------------------

subroutine filter_ensemble_inflate(ens_handle, inflate_copy, inflate, ENS_MEAN_COPY)

type(ensemble_type),         intent(inout) :: ens_handle
integer,                     intent(in)    :: inflate_copy, ENS_MEAN_COPY
type(adaptive_inflate_type), intent(inout) :: inflate

integer :: j, group, grp_bot, grp_top, grp_size

! Assumes that the ensemble is copy complete
call prepare_to_update_copies(ens_handle)

! Inflate each group separately;  Divide ensemble into num_groups groups
grp_size = ens_size / num_groups

do group = 1, num_groups
   grp_bot = (group - 1) * grp_size + 1
   grp_top = grp_bot + grp_size - 1
   ! Compute the mean for this group
   call compute_copy_mean(ens_handle, grp_bot, grp_top, ENS_MEAN_COPY)

   do j = 1, ens_handle%my_num_vars
      call inflate_ens(inflate, ens_handle%copies(grp_bot:grp_top, j), &
         ens_handle%copies(ENS_MEAN_COPY, j), ens_handle%copies(inflate_copy, j))
   end do
end do

end subroutine filter_ensemble_inflate

!-------------------------------------------------------------------------

subroutine obs_space_diagnostics(obs_fwd_op_ens_handle, qc_ens_handle, ens_size, &
   seq, keys, prior_post, num_output_members, members_index, &
   obs_val_index, OBS_KEY_COPY, &
   ens_mean_index, ens_spread_index, num_obs_in_set, &
   OBS_MEAN_START, OBS_VAR_START, OBS_GLOBAL_QC_COPY, OBS_VAL_COPY, &
   OBS_ERR_VAR_COPY, DART_qc_index)

! Do prior observation space diagnostics on the set of obs corresponding to keys

type(ensemble_type),     intent(inout) :: obs_fwd_op_ens_handle, qc_ens_handle
integer,                 intent(in)    :: ens_size
integer,                 intent(in)    :: num_obs_in_set
integer,                 intent(in)    :: keys(num_obs_in_set), prior_post
integer,                 intent(in)    :: num_output_members, members_index
integer,                 intent(in)    :: obs_val_index
integer,                 intent(in)    :: OBS_KEY_COPY
integer,                 intent(in)    :: ens_mean_index, ens_spread_index
type(obs_sequence_type), intent(inout) :: seq
integer,                 intent(in)    :: OBS_MEAN_START, OBS_VAR_START
integer,                 intent(in)    :: OBS_GLOBAL_QC_COPY, OBS_VAL_COPY
integer,                 intent(in)    :: OBS_ERR_VAR_COPY, DART_qc_index

integer               :: j, k, ens_offset, forward_min, forward_max
integer               :: forward_unit, ivalue
real(r8)              :: error, diff_sd, ratio
real(r8), allocatable :: obs_temp(:)
real(r8)              :: obs_prior_mean, obs_prior_var, obs_val, obs_err_var
real(r8)              :: rvalue(1)

! Do verbose forward operator output if requested
if(output_forward_op_errors) call verbose_forward_op_output(qc_ens_handle, prior_post, ens_size, keys)

! Make var complete for get_copy() calls below.
! Can you use a gather instead of a transpose and get copy?
call all_copies_to_all_vars(obs_fwd_op_ens_handle)

! allocate temp space for sending data - surely only task 0 needs to allocate this?
allocate(obs_temp(num_obs_in_set))

! Update the ensemble mean
! Get this copy to process 0
call get_copy(map_task_to_pe(obs_fwd_op_ens_handle, 0), obs_fwd_op_ens_handle, OBS_MEAN_START, obs_temp) 
! Only pe 0 gets to write the sequence
if(my_task_id() == 0) then
     ! Loop through the observations for this time
     do j = 1, obs_fwd_op_ens_handle%num_vars
      rvalue(1) = obs_temp(j)
      call replace_obs_values(seq, keys(j), rvalue, ens_mean_index)
     end do
  endif

! Update the ensemble spread
! Get this copy to process 0
call get_copy(map_task_to_pe(obs_fwd_op_ens_handle, 0), obs_fwd_op_ens_handle, OBS_VAR_START, obs_temp)
! Only pe 0 gets to write the sequence
if(my_task_id() == 0) then
   ! Loop through the observations for this time
   do j = 1, obs_fwd_op_ens_handle%num_vars
      ! update the spread in each obs
      if (obs_temp(j) /= missing_r8) then
         rvalue(1) = sqrt(obs_temp(j))
      else
         rvalue(1) = obs_temp(j)
      endif
      call replace_obs_values(seq, keys(j), rvalue, ens_spread_index)
   end do
endif

! May be possible to only do this after the posterior call...
! Update any requested ensemble members
ens_offset = members_index + 4
! Update all of these ensembles that are required to sequence file
do k = 1, num_output_members
   ! Get this copy on pe 0
   call get_copy(map_task_to_pe(obs_fwd_op_ens_handle, 0), obs_fwd_op_ens_handle, k, obs_temp)
   ! Only task 0 gets to write the sequence
   if(my_task_id() == 0) then
      ! Loop through the observations for this time
      do j = 1, obs_fwd_op_ens_handle%num_vars
         ! update the obs values 
         rvalue(1) = obs_temp(j)
         ivalue = ens_offset + 2 * (k - 1)
         call replace_obs_values(seq, keys(j), rvalue, ivalue)
      end do
   endif
end do

! Update the qc global value
call get_copy(map_task_to_pe(obs_fwd_op_ens_handle, 0), obs_fwd_op_ens_handle, OBS_GLOBAL_QC_COPY, obs_temp)
! Only task 0 gets to write the observations for this time
if(my_task_id() == 0) then
   ! Loop through the observations for this time
   do j = 1, obs_fwd_op_ens_handle%num_vars
      rvalue(1) = obs_temp(j)
      call replace_qc(seq, keys(j), rvalue, DART_qc_index)
   end do
endif

! clean up.
deallocate(obs_temp)

end subroutine obs_space_diagnostics

!-------------------------------------------------------------------------

subroutine filter_sync_keys_time(ens_handle, key_bounds, num_obs_in_set, time1, time2)

integer,             intent(inout)  :: key_bounds(2), num_obs_in_set
type(time_type),     intent(inout)  :: time1, time2
type(ensemble_type), intent(in)     :: ens_handle

! Have owner of copy 1 broadcast these values to all other tasks.
! Only tasks which contain copies have this info; doing it this way
! allows ntasks > nens to work.

real(r8) :: rkey_bounds(2), rnum_obs_in_set(1)
real(r8) :: rtime(4)
integer  :: days, secs
integer  :: copy1_owner, owner_index

call get_copy_owner_index(1, copy1_owner, owner_index)

if( ens_handle%my_pe == copy1_owner) then
   rkey_bounds = key_bounds
   rnum_obs_in_set(1) = num_obs_in_set
   call get_time(time1, secs, days)
   rtime(1) = secs
   rtime(2) = days
   call get_time(time2, secs, days)
   rtime(3) = secs
   rtime(4) = days
   call broadcast_send(map_pe_to_task(ens_handle, copy1_owner), rkey_bounds, rnum_obs_in_set, rtime)
else
   call broadcast_recv(map_pe_to_task(ens_handle, copy1_owner), rkey_bounds, rnum_obs_in_set, rtime)
   key_bounds =     nint(rkey_bounds)
   num_obs_in_set = nint(rnum_obs_in_set(1))
   time1 = set_time(nint(rtime(1)), nint(rtime(2)))
   time2 = set_time(nint(rtime(3)), nint(rtime(4)))
endif

end subroutine filter_sync_keys_time

!-------------------------------------------------------------------------

subroutine set_trace(trace_execution, output_timestamps, silence)

logical, intent(in) :: trace_execution
logical, intent(in) :: output_timestamps
logical, intent(in) :: silence

! Set whether other modules trace execution with messages
! and whether they output timestamps to trace overall performance

! defaults
trace_level     = 0
timestamp_level = 0

! selectively turn stuff back on
if (trace_execution)   trace_level     = 1
if (output_timestamps) timestamp_level = 1

! turn as much off as possible
if (silence) then
   trace_level     = -1
   timestamp_level = -1
endif

call set_smoother_trace(trace_level, timestamp_level)
call set_obs_model_trace(trace_level, timestamp_level)
call set_assim_tools_trace(trace_level, timestamp_level)

end subroutine set_trace

!-------------------------------------------------------------------------

subroutine trace_message(msg, label, threshold)

character(len=*), intent(in)           :: msg
character(len=*), intent(in), optional :: label
integer,          intent(in), optional :: threshold

! Write message to stdout and log file.
integer :: t

t = 0
if (present(threshold)) t = threshold

if (trace_level <= t) return

if (.not. do_output()) return

if (present(label)) then
   call error_handler(E_MSG,trim(label),trim(msg))
else
   call error_handler(E_MSG,'filter trace:',trim(msg))
endif

end subroutine trace_message

!-------------------------------------------------------------------------

subroutine timestamp_message(msg, sync)

character(len=*), intent(in) :: msg
logical, intent(in), optional :: sync

! Write current time and message to stdout and log file. 
! if sync is present and true, sync mpi jobs before printing time.

if (timestamp_level <= 0) return

if (present(sync)) then
  if (sync) call task_sync()
endif

if (do_output()) call timestamp(' '//trim(msg), pos='brief')  ! was debug

end subroutine timestamp_message

!-------------------------------------------------------------------------

subroutine print_ens_time(ens_handle, msg)

type(ensemble_type), intent(in) :: ens_handle
character(len=*), intent(in) :: msg

! Write message to stdout and log file.
type(time_type) :: mtime

if (trace_level <= 0) return

if (do_output()) then
   if (get_my_num_copies(ens_handle) < 1) return
   call get_ensemble_time(ens_handle, 1, mtime)
   call print_time(mtime, ' filter trace: '//msg, logfileunit)
   call print_time(mtime, ' filter trace: '//msg)
endif

end subroutine print_ens_time

!-------------------------------------------------------------------------

subroutine print_obs_time(seq, key, msg)

type(obs_sequence_type), intent(in) :: seq
integer, intent(in) :: key
character(len=*), intent(in), optional :: msg

! Write time of an observation to stdout and log file.
type(obs_type) :: obs
type(obs_def_type) :: obs_def
type(time_type) :: mtime

if (trace_level <= 0) return

if (do_output()) then
   call init_obs(obs, 0, 0)
   call get_obs_from_key(seq, key, obs)
   call get_obs_def(obs, obs_def)
   mtime = get_obs_def_time(obs_def)
   call print_time(mtime, ' filter trace: '//msg, logfileunit)
   call print_time(mtime, ' filter trace: '//msg)
   call destroy_obs(obs)
endif

end subroutine print_obs_time

!-------------------------------------------------------------------------
!> write out failed forward operators
!> This was part of obs_space_diagnostics
subroutine verbose_forward_op_output(qc_ens_handle, prior_post, ens_size, keys)

type(ensemble_type), intent(inout) :: qc_ens_handle
integer,             intent(in)    :: prior_post
integer,             intent(in)    :: ens_size
integer,             intent(in)    :: keys(:) ! I think this is still var size

character*12 :: task
integer :: j, i
integer :: forward_unit

write(task, '(i6.6)') my_task_id()

! all tasks open file?
if(prior_post == PRIOR_DIAG) then
   forward_unit = open_file('prior_forward_ope_errors' // task, 'formatted', 'append')
else
   forward_unit = open_file('post_forward_ope_errors' // task, 'formatted', 'append')
endif

! qc_ens_handle is a real representing an integer; values /= 0 get written out
do i = 1, ens_size
   do j = 1, qc_ens_handle%my_num_vars
      if(nint(qc_ens_handle%copies(i, j)) /= 0) write(forward_unit, *) i, keys(j), nint(qc_ens_handle%copies(i, j))
   end do
end do

call close_file(forward_unit)

end subroutine verbose_forward_op_output

!------------------------------------------------------------------

subroutine perturb_copies(state_ens_handle, pert_amp)

type(ensemble_type), intent(inout) :: state_ens_handle
real(r8),            intent(in)    :: pert_amp

type(random_seq_type) :: random_seq

logical :: interf_provided, allow_missing
integer :: i, j, num_ens

!> if it's possible to have missing values in the state
!> then you have to look for them and skip them when perturbing
allow_missing = get_missing_ok_status()

num_ens = state_ens_handle%num_copies - state_ens_handle%num_extras

call pert_model_copies(state_ens_handle, pert_amp, interf_provided)
if(.not. interf_provided) then
   call init_random_seq(random_seq, my_task_id())
   do i=1,state_ens_handle%my_num_vars
      NEXT_ENS: do j=1,num_ens
         if (allow_missing) then
            if (state_ens_handle%copies(j,i) == MISSING_R8) cycle NEXT_ENS
         endif

         state_ens_handle%copies(j,i) = random_gaussian(random_seq, &
                                        state_ens_handle%copies(j,i), pert_amp)
      enddo NEXT_ENS
   enddo
endif

end subroutine perturb_copies

!------------------------------------------------------------------

subroutine set_copy_time(ens_handle, copy_num, ens_time)

type(ensemble_type), intent(inout) :: ens_handle
integer,             intent(in)    :: copy_num
type(time_type),     intent(in)    :: ens_time

integer :: owner, owners_index

! Set time for a given copy of an ensemble
call get_copy_owner_index(copy_num, owner, owners_index)
if(ens_handle%my_pe == owner) then
   call set_ensemble_time(ens_handle, owners_index, ens_time)
endif

end subroutine set_copy_time

!==================================================================
! TEST FUNCTIONS BELOW THIS POINT
!------------------------------------------------------------------
!> dump out obs_copies to file
subroutine test_obs_copies(obs_fwd_op_ens_handle, information)

type(ensemble_type), intent(in) :: obs_fwd_op_ens_handle
character(len=*),    intent(in) :: information

character*20  :: task_str !< string to hold the task number
character*129 :: file_obscopies !< output file name
integer :: i

write(task_str, '(i10)') obs_fwd_op_ens_handle%my_pe
file_obscopies = TRIM('obscopies_' // TRIM(ADJUSTL(information)) // TRIM(ADJUSTL(task_str)))
open(15, file=file_obscopies, status ='unknown')

do i = 1, obs_fwd_op_ens_handle%num_copies - 4
   write(15, *) obs_fwd_op_ens_handle%copies(i,:)
enddo

close(15)

end subroutine test_obs_copies

!-------------------------------------------------------------------
end module filter_mod

! <next few lines under version control, do not edit>
! $URL$
! $Id$
! $Revision$
! $Date$
