module kwt_route_module

!numeric type
use nrtype
! data types
USE dataTypes,  only : FPOINT            ! particle
USE dataTypes,  only : KREACH            ! collection of particles in a given reach
USE dataTypes,  only : STRFLX            ! fluxes in each reach
USE dataTypes,  only : RCHTOPO           ! Network topology
USE dataTypes,  only : RCHPRP            ! Reach parameter
! global data
USE public_var, only : verySmall         ! a very small value
USE public_var, only : realMissing       ! missing value for real number
USE public_var, only : integerMissing    ! missing value for integer number
! utilities
use nr_utility_module, only : arth       ! Num. Recipies utilities
USE time_utils_module, only : elapsedSec ! calculate the elapsed time

! privary
implicit none
private

public::kwt_route
public::kwt_route_orig

contains

 ! *********************************************************************
 ! subroutine: route kinematic waves through the river network
 ! *********************************************************************
 SUBROUTINE kwt_route(iens,                 & ! input: ensemble index
                      river_basin,          & ! input: river basin information (mainstem, tributary outlet etc.)
                      T0,T1,                & ! input: start and end of the time step
                      basinType,            & ! input: integer to indicate basin type (1-> tributary, 2-> mainstem)
                      ixDesire,             & ! input: reachID to be checked by on-screen pringing
                      NETOPO_in,            & ! input: reach topology data structure
                      RPARAM_in,            & ! input: reach parameter data structure
                      KROUTE_out,           & ! inout: reach state data structure
                      RCHFLX_out,           & ! inout: reach flux data structure
                      ierr,message,         & ! output: error control
                      ixSubRch)               ! optional input: subset of reach indices to be processed
 USE dataTypes,  only : basin                 ! river basin data type
 implicit none
 ! Input
 integer(i4b), intent(in)                 :: iEns                  ! ensemble member
 type(basin),  intent(in), allocatable    :: river_basin(:)        ! river basin information (mainstem, tributary outlet etc.)
 real(dp),     intent(in)                 :: T0,T1                 ! start and end of the time step (seconds)
 integer(i4b), intent(in)                 :: basinType             ! integer to indicate basin type (1-> tributary, 2-> mainstem)
 integer(i4b), intent(in)                 :: ixDesire              ! index of the reach for verbose output
 type(RCHTOPO),intent(in),    allocatable :: NETOPO_in(:)          ! River Network topology
 type(RCHPRP), intent(in),    allocatable :: RPARAM_in(:)          ! River reach parameter
 ! inout
 type(KREACH), intent(inout), allocatable :: KROUTE_out(:,:)       ! reach state data
 type(STRFLX), intent(inout), allocatable :: RCHFLX_out(:,:)       ! Reach fluxes (ensembles, space [reaches]) for decomposed domains
 ! output variables
 integer(i4b), intent(out)                :: ierr                  ! error code
 character(*), intent(out)                :: message               ! error message
 ! input (optional)
 integer(i4b), intent(in),   optional     :: ixSubRch(:)           ! subset of reach indices to be processed
 ! local variables
 logical(lgt), allocatable                :: doRoute(:)            ! logical to indicate which reaches are processed
 logical(lgt)                             :: doMainstem            ! logical to indicate mainstem is defined for a basin
 integer(i4b)                             :: LAKEFLAG=0            ! >0 if processing lakes
 integer(i4b)                             :: nSeg                  ! number of reaches in the network
 integer(i4b)                             :: nOuts                 ! number of outlets
 integer(i4b)                             :: nTrib                 ! number of tributary basins
 integer(i4b)                             :: nStem                 ! number of mainstem in each level
 integer(i4b)                             :: iRch, jRch            ! loop indices - reach
 integer(i4b)                             :: iOut                  ! loop indices - basin outlet
 integer(i4b)                             :: iTrib                 ! loop indices - tributary
 integer(i4b)                             :: iLevel                ! loop indices - mainstem level
 integer(i4b)                             :: iStem                 ! loop inidces - mainstem
 integer(i4b)                             :: maxLevel,minLevel     ! max. and min. mainstem levels
 character(len=strLen)                    :: cmessage              ! error message for downwind routine
 ! variables needed for timing
! integer(i4b)                             :: nThreads              ! number of threads
! integer(i4b)                             :: omp_get_num_threads   ! get the number of threads
! integer(i4b)                             :: omp_get_thread_num
! integer(i4b), allocatable                :: ixThread(:)           ! thread id
! integer*8,    allocatable                :: openMPend(:)          ! time for the start of the parallelization section
! integer*8,    allocatable                :: timeTribStart(:)      ! time Tributaries start
! real(dp),     allocatable                :: timeTrib(:)           ! time spent on each Tributary
 integer*8                                :: cr,startTime,endTime  ! rate, start and end time stamps
 real(dp)                                 :: elapsedTime           ! elapsed time for the process

 ! initialize error control
 ierr=0; message='kwt_route/'

 CALL system_clock(count_rate=cr)

 nSeg = size(NETOPO_in)

 allocate(doRoute(nSeg), stat=ierr)
 if(ierr/=0)then; message=trim(message)//'problem allocating space for [doRoute]'; return; endif

 if (present(ixSubRch))then
  doRoute(:)=.false.
  doRoute(ixSubRch) = .true. ! only subset of reaches are on
 else
  doRoute(:)=.true.          ! every reach is on
 endif

 ! Number of Outlets
 nOuts = size(river_basin)

 do iOut=1,nOuts

   doMainstem = .false.
   if (allocated(river_basin(iOut)%level)) then
     doMainstem = .true.
     maxLevel = 1
     do iLevel=1,size(river_basin(iOut)%level)
       if (.not. allocated(river_basin(iOut)%level(iLevel)%mainstem)) cycle
       if (iLevel > maxLevel) maxLevel = iLevel
     end do
     minLevel = size(river_basin(iOut)%level)
     do iLevel=maxLevel,1,-1
       if (.not. allocated(river_basin(iOut)%level(iLevel)%mainstem)) cycle
       if (iLevel < minLevel) minLevel = iLevel
     end do
   end if

   nTrib=size(river_basin(iOut)%tributary)

!   allocate(ixThread(nTrib), openMPend(nTrib), timeTrib(nTrib), timeTribStart(nTrib), stat=ierr)
!   if(ierr/=0)then; message=trim(message)//trim(cmessage)//': unable to allocate space for Trib timing'; return; endif
!   timeTrib(:) = realMissing
!   ixThread(:) = integerMissing

   ! 1. Route tributary reaches (parallel)
!   call system_clock(startTime)
!$OMP parallel default(none)                            &
!$OMP          private(jRch, iRch)                      & ! private for a given thread
!$OMP          private(ierr, cmessage)                  & ! private for a given thread
!$OMP          shared(T0,T1)                            & ! private for a given thread
!$OMP          shared(LAKEFLAG)                         & ! private for a given thread
!$OMP          shared(river_basin)                      & ! data structure shared
!$OMP          shared(doRoute)                          & ! data array shared
!$OMP          shared(NETOPO_in)                        & ! data structure shared
!$OMP          shared(RPARAM_in)                        & ! data structure shared
!$OMP          shared(KROUTE_out)                       & ! data structure shared
!$OMP          shared(RCHFLX_out)                       & ! data structure shared
!$OMP          shared(basinType)                        & ! scalar varaible shared
!$OMP          shared(iEns, iOut, ixDesire)             & ! indices shared
!!$OMP          shared(openMPend, nThreads)              & ! timing variables shared
!!$OMP          shared(timeTribStart)                    & ! timing variables shared
!!$OMP          shared(timeTrib)                         & ! timing variables shared
!!$OMP          shared(ixThread)                         & ! thread id array shared
!$OMP          firstprivate(nTrib)
!   nThreads = 1
!!$ nThreads = omp_get_num_threads()

!$OMP DO schedule(dynamic, 1)   ! chunk size of 1
   do iTrib = 1,nTrib
!!$    ixThread(iTrib) = omp_get_thread_num()
!    call system_clock(timeTribStart(iTrib))
     do iRch=1,river_basin(iOut)%tributary(iTrib)%nRch
       jRch  = river_basin(iOut)%tributary(iTrib)%segIndex(iRch)
       if (.not. doRoute(jRch)) cycle
       ! route kinematic waves through the river network
       call QROUTE_RCH(iEns,jRch,           & ! input: array indices
                       ixDesire,            & ! input: index of the desired reach
                       basinType,           & ! input: integer to indicate basin type (1-> tributary, 2-> mainstem)
                       T0,T1,               & ! input: start and end of the time step
                       LAKEFLAG,            & ! input: flag if lakes are to be processed
                       NETOPO_in,           & ! input: reach topology data structure
                       RPARAM_in,           & ! input: reach parameter data structure
                       KROUTE_out,          & ! inout: reach state data structure
                       RCHFLX_out,          & ! inout: reach flux data structure
                       ierr,cmessage)         ! output: error control
       !if (ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
     end do  ! (looping through stream segments)
!     call system_clock(openMPend(iTrib))
!     timeTrib(iTrib) = real(openMPend(iTrib)-timeTribStart(iTrib), kind(dp))
   end do  ! (looping through stream segments)
!$OMP END DO
!$OMP END PARALLEL

!   call system_clock(endTime)
!   elapsedTime = real(endTime-startTime, kind(dp))/real(cr)
!   write(*,"(A,1PG15.7,A)") '  total elapsed trib = ', elapsedTime, ' s'

!   write(*,'(a)') 'iTrib nSeg ixThread nThreads StartTime EndTime'
!   do iTrib=1,nTrib
!     write(*,'(4(i5,1x),2(I20,1x))') iTrib, river_basin(iOut)%tributary(iTrib)%nRch, ixThread(iTrib), nThreads, timeTribStart(iTrib), openMPend(iTrib)
!   enddo
!   deallocate(ixThread, openMPend, timeTrib, timeTribStart, stat=ierr)
!   if(ierr/=0)then; message=trim(message)//trim(cmessage)//': unable to deallocate space for Trib timing'; return; endif

   if (.not.doMainstem) cycle ! For small basin, no mainstem defined
   ! 2. Route mainstems
!   call system_clock(startTime)
   do iLevel=maxLevel,minLevel,-1
     nStem = size(river_basin(iOut)%level(iLevel)%mainstem)
!$OMP PARALLEL default(none)                            &
!$OMP          private(jRch, iRch)                      & ! private for a given thread
!$OMP          private(iStem)                           & ! private for a given thread
!$OMP          private(ierr, cmessage)                  & ! private for a given thread
!$OMP          shared(T0,T1)                            & ! private for a given thread
!$OMP          shared(LAKEFLAG)                         & ! private for a given thread
!$OMP          shared(river_basin)                      & ! data structure shared
!$OMP          shared(doRoute)                          & ! data array shared
!$OMP          shared(NETOPO_in)                        & ! data structure shared
!$OMP          shared(RPARAM_in)                        & ! data structure shared
!$OMP          shared(KROUTE_out)                       & ! data structure shared
!$OMP          shared(RCHFLX_out)                       & ! data structure shared
!$OMP          shared(basinType)                        & ! scalar varaible shared
!$OMP          shared(iLevel)                           & ! private for a given thread
!$OMP          shared(iEns, iOut, ixDesire)             & ! indices shared
!$OMP          firstprivate(nStem)
!$OMP DO schedule(dynamic,1)
     do iStem = 1,nStem
       do iRch=1,river_basin(iOut)%level(iLevel)%mainstem(iStem)%nRch
         jRch = river_basin(iOut)%level(iLevel)%mainstem(iStem)%segIndex(iRch)
         if (.not. doRoute(jRch)) cycle
         ! route kinematic waves through the river network
         call QROUTE_RCH(iens,jRch,           & ! input: array indices
                         ixDesire,            & ! input: index of the desired reach
                         basinType,           & ! input: integer to indicate basin type (1-> tributary, 2-> mainstem)
                         T0,T1,               & ! input: start and end of the time step
                         LAKEFLAG,            & ! input: flag if lakes are to be processed
                         NETOPO_in,           & ! input: reach topology data structure
                         RPARAM_in,           & ! input: reach parameter data structure
                         KROUTE_out,          & ! inout: reach state data structure
                         RCHFLX_out,          & ! inout: reach flux data structure
                         ierr,cmessage)         ! output: error control
!         if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
       end do
     enddo
!$OMP END DO
!$OMP END PARALLEL
   end do
!   call system_clock(endTime)
!   elapsedTime = real(endTime-startTime, kind(dp))/real(cr)
!   write(*,"(A,1PG15.7,A)") '  total elapsed mainstem = ', elapsedTime, ' s'

 end do ! basin loop

 END SUBROUTINE kwt_route


 SUBROUTINE kwt_route_orig(iens,                 & ! input: ensemble index
                           river_basin,          & ! input: river basin information (mainstem, tributary outlet etc.)
                           T0,T1,                & ! input: start and end of the time step
                           basinType,            & ! input: integer to indicate basin type (1-> tributary, 2-> mainstem)
                           ixDesire,             & ! input: reachID to be checked by on-screen pringing
                           NETOPO_in,            & ! input: reach topology data structure
                           RPARAM_in,            & ! input: reach parameter data structure
                           KROUTE_out,           & ! inout: reach state (wave) data structure
                           RCHFLX_out,           & ! inout: reach flux data structure
                           ierr,message,         & ! output: error control
                           ixSubRch)               ! optional input: subset of reach indices to be processed
  ! global routing data
  USE dataTypes,  only : basin                     ! river basin data type

  implicit none
  ! Input
   integer(i4b), intent(in)                 :: iens            ! ensemble member
   type(basin),  intent(in),    allocatable :: river_basin(:)  ! river basin information (mainstem, tributary outlet etc.)
   real(dp),     intent(in)                 :: T0,T1           ! start and end of the time step (seconds)
   integer(i4b), intent(in)                 :: basinType       ! integer to indicate basin type (1-> tributary, 2-> mainstem)
   integer(i4b), intent(in)                 :: ixDesire        ! index of the reach for verbose output
   type(RCHTOPO),intent(in),    allocatable :: NETOPO_in(:)    ! River Network topology
   type(RCHPRP), intent(in),    allocatable :: RPARAM_in(:)    ! River reach parameter
   ! inout
   type(KREACH), intent(inout), allocatable :: KROUTE_out(:,:) ! reach state data
   TYPE(STRFLX), intent(inout), allocatable :: RCHFLX_out(:,:) ! Reach fluxes (ensembles, space [reaches]) for decomposed domains
   ! output variables
   integer(i4b), intent(out)                :: ierr            ! error code
   character(*), intent(out)                :: message         ! error message
   ! input (optional)
   integer(i4b), intent(in),   optional     :: ixSubRch(:)     ! subset of reach indices to be processed
   ! local variables
   integer(i4b)                             :: nSeg            ! number of reach segments in the network
   integer(I4B)                             :: LAKEFLAG=0      ! >0 if processing lakes
   integer(i4b)                             :: iSeg, jSeg      ! reach indices
   logical(lgt), allocatable                :: doRoute(:)      ! logical to indicate which reaches are processed
   character(len=strLen)                    :: cmessage        ! error message for downwind routine
   integer*8                                :: startTime,endTime ! date/time for the start and end of the initialization
   real(dp)                                 :: elapsedTime     ! elapsed time for the process

  ! initialize error control
  ierr=0; message='kwt_route_orig/'

  elapsedTime = 0._dp
  call system_clock(startTime)

  ! check
  if (size(NETOPO_in)/=size(RCHFLX_out(iens,:))) then
   ierr=20; message=trim(message)//'sizes of NETOPO and RCHFLX mismatch'; return
  endif

  ! Initialize CHEC_IRF to False.
!  RCHFLX_out(iEns,:)%CHECK_KWT=.False.

  nSeg = size(NETOPO_in)

  allocate(doRoute(nSeg), stat=ierr)
  if(ierr/=0)then; message=trim(message)//'problem allocating space for [doRoute]'; return; endif

  if (present(ixSubRch))then
   doRoute(:)=.false.
   doRoute(ixSubRch) = .true. ! only subset of reaches are on
  else
   doRoute(:)=.true.          ! every reach is on
  endif

  ! route streamflow through the river network
  do iSeg=1,nSeg

   ! identify reach to process
   jSeg = NETOPO_in(iSeg)%RHORDER

   if (.not. doRoute(jSeg)) cycle
   ! route kinematic waves through the river network
   call QROUTE_RCH(iens,jSeg,           & ! input: array indices
                   ixDesire,            & ! input: index of the desired reach
                   basinType,           & ! input: integer to indicate basin type (1-> tributary, 2-> mainstem)
                   T0,T1,               & ! input: start and end of the time step
                   LAKEFLAG,            & ! input: flag if lakes are to be processed
                   NETOPO_in,           & ! input: reach topology data structure
                   RPARAM_in,           & ! input: reach parameter data structure
                   KROUTE_out,          & ! inout: reach state data structure
                   RCHFLX_out,          & ! inout: reach flux data structure
                   ierr,cmessage)         ! output: error control
   if (ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

  end do  ! (looping through stream segments)

  call system_clock(endTime)
  elapsedTime = real(endTime-startTime, kind(dp))/10e8_dp
!  write(*,"(A,1PG15.7,A)") '  total elapsed entire = ', elapsedTime, ' s'

 END SUBROUTINE kwt_route_orig

 ! *********************************************************************
 ! subroutine: route kinematic waves at one segment
 ! *********************************************************************
 subroutine QROUTE_RCH(IENS,JRCH,    & ! input: array indices
                       ixDesire,     & ! input: index of the reach for verbose output
                       basinType,    & ! input: integer to indicate basin type (1-> tributary, 2-> mainstem)
                       T0,T1,        & ! input: start and end of the time step
                       LAKEFLAG,     & ! input: flag if lakes are to be processed
                       NETOPO_in,    & ! input: reach topology data structure
                       RPARAM_in,    & ! input: reach parameter data structure
                       KROUTE_out,   & ! inout: reach state data structure
                       RCHFLX_out,   & ! inout: reach flux data structure
                       ierr,message, & ! output: error control
                       RSTEP)          ! optional input: retrospective time step offset
 ! public data
 USE public_var, only : MAXQPAR        ! maximum number of waves per reach
 ! ----------------------------------------------------------------------------------------
 ! Creator(s):
 !   Ross Woods, 1997 (original code)
 !   Martyn Clark, 2006 (current version)
 !   Martyn Clark, 2012 (modified as a standalone module)
 !
 ! ----------------------------------------------------------------------------------------
 ! Purpose:
 !
 !   Route kinematic waves through the river network
 !
 ! ----------------------------------------------------------------------------------------
 ! Method:
 !
 !   Flow routing is performed using a lagrangian one-dimensional Kinematic routing
 !   scheme.  Flow generated from each catchment is tracked through the river network.
 !   For each river segment, we compute the time each particle is expected to exit the
 !   river segment (travel time = length/celerity).  If the "exit time" occurs before
 !   the end of the time step, the particle is propagated to the downstream segment.
 !   The "exit time" then becomes the time the particle entered the downstream segment.
 !   This process is repeated for all river segments.  River segments are processed in
 !   order from upstream segments to downstream segments, meaning that it is possible
 !   for a particle to travel through several segments in a given time step.
 !
 !   Time step averages for each time step are computed by integrating over all the
 !   flow points that exit a river segment in a given time step.  To avoid boundary
 !   problems in the interpolation, the last routed wave from the previous time step
 !   and the next wave that is expected to exit the segment are used.
 !
 ! ----------------------------------------------------------------------------------------
 ! Source:
 !
 !   Most computations were originally performed within calcts in Topnet ver7, with calls
 !   to subroutines in kinwav_v7.f
 !
 ! ----------------------------------------------------------------------------------------
 ! Modifications to Source (mclark@ucar.edu):
 !
 !   * code is more modular
 !
 !   * added additional comments
 !
 !   * all variables are defined (IMPLICIT NONE) and described (comments)
 !
 !   * use of a new data structure (KROUTE_out) to hold and update the flow particles
 !
 !   * upgrade to F90 (especially structured variables and dynamic memory allocation)
 !
 ! ----------------------------------------------------------------------------------------
 ! Future revisions:
 !
 !   (none planned)
 !
 ! ----------------------------------------------------------------------------------------
   implicit none
   ! Input
   integer(i4b), intent(in)                    :: IENS          ! ensemble member
   integer(i4b), intent(in)                    :: JRCH          ! reach to process
   integer(i4b), intent(in)                    :: ixDesire      ! index of the reach for verbose output
   integer(i4b), intent(in)                    :: basinType       ! integer to indicate basin type (1-> tributary, 2-> mainstem)
   real(dp),     intent(in)                    :: T0,T1         ! start and end of the time step (seconds)
   integer(i4b), intent(in)                    :: LAKEFLAG      ! >0 if processing lakes
   type(RCHTOPO),intent(in),    allocatable    :: NETOPO_in(:)  ! River Network topology
   type(RCHPRP), intent(in),    allocatable    :: RPARAM_in(:)  ! River reach parameter
   integer(i4b), intent(in), optional          :: RSTEP         ! retrospective time step offset
   ! inout
   type(KREACH), intent(inout), allocatable    :: KROUTE_out(:,:) ! reach state data
   TYPE(STRFLX), intent(inout), allocatable    :: RCHFLX_out(:,:) ! Reach fluxes (ensembles, space [reaches]) for decomposed domains
   ! output variables
   integer(i4b), intent(out)                   :: ierr          ! error code
   character(*), intent(out)                   :: message       ! error message
   ! (1) extract flow from upstream reaches and append to the non-routed flow in JRCH
   INTEGER(I4B)                                :: NUPS          ! number of upstream reaches
   REAL(DP),DIMENSION(:),allocatable           :: Q_JRCH        ! flow in downstream reach JRCH
   REAL(DP),DIMENSION(:),allocatable           :: TENTRY        ! entry time to JRCH (exit time u/s)
   INTEGER(I4B)                                :: NQ1           ! # flow particles
   ! (2) route flow within the current [JRCH] river segment
   INTEGER(I4B)                                :: ROFFSET       ! retrospective offset due to rstep
   REAL(DP)                                    :: T_START       ! start of time step
   REAL(DP)                                    :: T_END         ! end of time step
   REAL(DP),DIMENSION(:),allocatable           :: T_EXIT        ! time particle expected exit JRCH
   LOGICAL(LGT),DIMENSION(:),allocatable       :: FROUTE        ! routing flag .T. if particle exits
   INTEGER(I4B)                                :: NQ2           ! # flow particles (<=NQ1 b/c merge)
   ! (3) calculate time-step averages
   INTEGER(I4B)                                :: NR            ! # routed particles
   INTEGER(I4B)                                :: NN            ! # non-routed particles
   REAL(DP),DIMENSION(2)                       :: TNEW          ! start/end of time step
   REAL(DP),DIMENSION(1)                       :: QNEW          ! interpolated flow
   ! (4) housekeeping
   REAL(DP)                                    :: Q_END         ! flow at the end of the timestep
   REAL(DP)                                    :: TIMEI         ! entry time at the end of the timestep
   TYPE(FPOINT),allocatable,DIMENSION(:)       :: NEW_WAVE      ! temporary wave
   LOGICAL(LGT)                                :: INIT=.TRUE.   ! used to initialize pointers
   ! random stuff
   integer(i4b)                                :: IWV           ! rech index
   character(len=strLen)                       :: fmt1,fmt2     ! format string
   character(len=strLen)                       :: CMESSAGE      ! error message for downwind routine

   ! initialize error control
   ierr=0; message='QROUTE_RCH/'
   ! ----------------------------------------------------------------------------------------
   ! (0) INITIALIZE POINTERS
   ! ----------------------------------------------------------------------------------------
   if(INIT) then
     INIT=.false.
   endif

   if(JRCH==ixDesire) write(*,"('JRCH=',I10)") JRCH
   if(JRCH==ixDesire) write(*,"('T0-T1=',F20.7,1x,F20.7)") T0, T1

   RCHFLX_out(IENS,JRCH)%TAKE=0.0_dp ! initialize take from this reach
    ! ----------------------------------------------------------------------------------------
    ! (1) EXTRACT FLOW FROM UPSTREAM REACHES & APPEND TO THE NON-ROUTED FLOW PARTICLES IN JRCH
    ! ----------------------------------------------------------------------------------------
    NUPS = count(NETOPO_in(JRCH)%goodBas)        ! number of desired upstream reaches
    !NUPS = size(NETOPO_in(JRCH)%UREACHI)        ! number of upstream reaches
    IF (NUPS.GT.0) THEN
      call GETUSQ_RCH(IENS,JRCH,LAKEFLAG,T0,T1,ixDesire, & ! input
                      NETOPO_in,RPARAM_in,RCHFLX_out,    & ! input
                      KROUTE_out,                        & ! inout
                      Q_JRCH,TENTRY,T_EXIT,ierr,cmessage,& ! output
                      RSTEP)                               ! optional input
      if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
      ! check for negative flow
      if (MINVAL(Q_JRCH).lt.0.0_dp) then
        ierr=20; message=trim(message)//'negative flow extracted from upstream reach'; return
      endif
      ! check
      if(JRCH==ixDesire)then
        write(fmt1,'(A,I5,A)') '(A,1X',size(Q_JRCH),'(1X,F20.7))'
        write(*,fmt1) 'Initial_Q_JRCH=', (Q_JRCH(IWV), IWV=0,size(Q_JRCH)-1)
      endif
    else
      ! set flow in headwater reaches to modelled streamflow from time delay histogram
      RCHFLX_out(IENS,JRCH)%REACH_Q = RCHFLX_out(IENS,JRCH)%BASIN_QR(1)
      if (allocated(KROUTE_out(IENS,JRCH)%KWAVE)) THEN
        deallocate(KROUTE_out(IENS,JRCH)%KWAVE,STAT=IERR)
        if(ierr/=0)then; message=trim(message)//'problem deallocating space for KROUTE_out'; return; endif
      endif
      allocate(KROUTE_out(IENS,JRCH)%KWAVE(0:0),STAT=ierr)
      if(ierr/=0)then; message=trim(message)//'problem allocating space for KROUTE_out(IENS,JRCH)%KWAVE(1)'; return; endif
      KROUTE_out(IENS,JRCH)%KWAVE(0)%QF=-9999
      KROUTE_out(IENS,JRCH)%KWAVE(0)%TI=-9999
      KROUTE_out(IENS,JRCH)%KWAVE(0)%TR=-9999
      KROUTE_out(IENS,JRCH)%KWAVE(0)%RF=.False.
      KROUTE_out(IENS,JRCH)%KWAVE(0)%QM=-9999
      ! check
      if(JRCH==ixDesire) print*, 'JRCH, RCHFLX_out(IENS,JRCH)%REACH_Q = ', JRCH, RCHFLX_out(IENS,JRCH)%REACH_Q
      return  ! no upstream reaches (routing for sub-basins done using time-delay histogram)
    endif
    ! ----------------------------------------------------------------------------------------
    ! (2) REMOVE FLOW PARTICLES (REDUCE MEMORY USAGE AND PROCESSING TIME)
    ! ----------------------------------------------------------------------------------------
    if (size(Q_JRCH).GT.MAXQPAR) then
      call REMOVE_RCH(MAXQPAR,Q_JRCH,TENTRY,T_EXIT,ierr,cmessage)
      if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
    endif
    NQ1 = SIZE(Q_JRCH)-1                                     ! -1 because of the zero element
    ! ----------------------------------------------------------------------------------------
    ! (3) ROUTE FLOW WITHIN THE CURRENT [JRCH] RIVER SEGMENT
    ! ----------------------------------------------------------------------------------------
    ! set the retrospective offset
    if (.not.present(RSTEP)) then
      ROFFSET = 0
    else
      ROFFSET = RSTEP
    endif
    ! set time boundaries
    T_START = T0 - (T1 - T0)*ROFFSET
    T_END   = T1 - (T1 - T0)*ROFFSET
    allocate(FROUTE(0:NQ1),STAT=IERR)
    if(ierr/=0)then; message=trim(message)//'problem allocating space for FROUTE'; return; endif
    FROUTE(0) = .TRUE.; FROUTE(1:NQ1)=.FALSE.  ! init. routing flags
    ! route flow through the current [JRCH] river segment (Q_JRCH in units of m2/s)
    call KINWAV_RCH(JRCH,T_START,T_END,ixDesire,                             & ! input: location and time
                    NETOPO_in, RPARAM_in,                                    & ! input: river data structure
                    Q_JRCH(1:NQ1),TENTRY(1:NQ1),T_EXIT(1:NQ1),FROUTE(1:NQ1), & ! inout: kwt states
                    NQ2,ierr,cmessage)                                         ! output:
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
    if(JRCH == ixDesire)then
      write(fmt1,'(A,I5,A)') '(A,1X',NQ1+1,'(1X,F20.7))'
      write(fmt2,'(A,I5,A)') '(A,1X',NQ1+1,'(1X,L))'
      write(*,fmt1) 'Q_JRCH=',(Q_JRCH(IWV), IWV=0,NQ1)
      write(*,fmt2) 'FROUTE=',(FROUTE(IWV), IWV=0,NQ1)
      write(*,fmt1) 'TENTRY=',(TENTRY(IWV), IWV=0,NQ1)
      write(*,fmt1) 'T_EXIT=',(T_EXIT(IWV), IWV=0,NQ1)
    endif
    ! ----------------------------------------------------------------------------------------
    ! (4) COMPUTE TIME-STEP AVERAGES
    ! ----------------------------------------------------------------------------------------
    NR = COUNT(FROUTE)-1   ! -1 because of the zero element (last routed)
    NN = NQ2-NR            ! number of non-routed points
    TNEW = (/T_START,T_END/)
    ! (zero position last routed; use of NR+1 instead of NR keeps next expected routed point)
    call INTERP_RCH(T_EXIT(0:NR+1),Q_JRCH(0:NR+1),TNEW,QNEW,IERR,CMESSAGE)
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
    if(JRCH == ixDesire) write(*,"('QNEW(1)=',1x,F10.7)") QNEW(1)
    ! m2/s --> m3/s + instantaneous runoff from basin
    RCHFLX_out(IENS,JRCH)%REACH_Q = QNEW(1)*RPARAM_in(JRCH)%R_WIDTH + RCHFLX_out(IENS,JRCH)%BASIN_QR(1)
    ! ----------------------------------------------------------------------------------------
    ! (5) HOUSEKEEPING
    ! ----------------------------------------------------------------------------------------
    ! compute the instantaneous flow at the end of the time step
    !   (last routed point)
    Q_END = Q_JRCH(NR) + &   !        (dQ/dT)                                 (dT)
             ( (Q_JRCH(NR+1)-Q_JRCH(NR)) / (T_EXIT(NR+1)-T_EXIT(NR)) ) * (T_END-T_EXIT(NR))
    ! compute an approximate entry time (needed for the remove routine later)
    TIMEI = TENTRY(NR) + &   !        (dT/dT)                                 (dT)
             ( (TENTRY(NR+1)-TENTRY(NR)) / (T_EXIT(NR+1)-T_EXIT(NR)) ) * (T_END-T_EXIT(NR))
    ! allocate space for the routed data (+1 to allocate space for the interpolated point)
    if (.not.allocated(KROUTE_out(IENS,JRCH)%KWAVE)) then
      ierr=20; message=trim(message)//'KROUTE_out is not associated'; return
    else
      deallocate(KROUTE_out(IENS,JRCH)%KWAVE, STAT=ierr)
      if(ierr/=0)then; message=trim(message)//'problem deallocating space for KROUTE_out(IENS,JRCH)%KWAVE'; return; endif
      allocate(KROUTE_out(IENS,JRCH)%KWAVE(0:NQ2+1),STAT=ierr)   ! NQ2 is number of points for kinematic routing
      if(ierr/=0)then; message=trim(message)//'problem allocating space for KROUTE_out(IENS,JRCH)%KWAVE(0:NQ2+1)'; return; endif
    endif
    ! insert the interpolated point (TI is irrelevant, as the point is "routed")
    KROUTE_out(IENS,JRCH)%KWAVE(NR+1)%QF=Q_END;   KROUTE_out(IENS,JRCH)%KWAVE(NR+1)%TI=TIMEI
    KROUTE_out(IENS,JRCH)%KWAVE(NR+1)%TR=T_END;   KROUTE_out(IENS,JRCH)%KWAVE(NR+1)%RF=.TRUE.
    ! add the output from kinwave...         - skip NR+1
    ! (when JRCH becomes IR routed points will be stripped out & the structures updated again)
    KROUTE_out(IENS,JRCH)%KWAVE(0:NR)%QF=Q_JRCH(0:NR); KROUTE_out(IENS,JRCH)%KWAVE(NR+2:NQ2+1)%QF=Q_JRCH(NR+1:NQ2)
    KROUTE_out(IENS,JRCH)%KWAVE(0:NR)%TI=TENTRY(0:NR); KROUTE_out(IENS,JRCH)%KWAVE(NR+2:NQ2+1)%TI=TENTRY(NR+1:NQ2)
    KROUTE_out(IENS,JRCH)%KWAVE(0:NR)%TR=T_EXIT(0:NR); KROUTE_out(IENS,JRCH)%KWAVE(NR+2:NQ2+1)%TR=T_EXIT(NR+1:NQ2)
    KROUTE_out(IENS,JRCH)%KWAVE(0:NR)%RF=FROUTE(0:NR); KROUTE_out(IENS,JRCH)%KWAVE(NR+2:NQ2+1)%RF=FROUTE(NR+1:NQ2)
    KROUTE_out(IENS,JRCH)%KWAVE(0:NQ2+1)%QM=-9999
    ! implement water use
    !IF (NUSER.GT.0.AND.UCFFLAG.GE.1) THEN
      !CALL EXTRACT_FROM_RCH(IENS,JRCH,NR,Q_JRCH,T_EXIT,T_END,TNEW)
    !ENDIF
    ! free up space for the next reach
    deallocate(Q_JRCH,TENTRY,T_EXIT,FROUTE,STAT=IERR)   ! FROUTE defined in this sub-routine
    if(ierr/=0)then; message=trim(message)//'problem deallocating space for [Q_JRCH, TENTRY, T_EXIT, FROUTE]'; return; endif
    ! ***
    ! remove flow particles from the most downstream reach
    ! if the last reach or lake inlet (and lakes are enabled), remove routed elements from memory
    IF ((NETOPO_in(JRCH)%DREACHI.LT.0 .and. basinType==2).OR. &  ! if the last reach, then there is no downstream reach
        (LAKEFLAG.EQ.1.AND.NETOPO_in(JRCH)%LAKINLT)) THEN ! if lake inlet
      ! copy data to a temporary wave
      if (allocated(NEW_WAVE)) THEN
        DEALLOCATE(NEW_WAVE,STAT=IERR)
        if(ierr/=0)then; message=trim(message)//'problem deallocating space for NEW_WAVE'; return; endif
      endif
      ALLOCATE(NEW_WAVE(0:NN),STAT=IERR)  ! NN = number non-routed (the zero element is the last routed point)
      if(ierr/=0)then; message=trim(message)//'problem allocating space for NEW_WAVE'; return; endif
      NEW_WAVE(0:NN) = KROUTE_out(IENS,JRCH)%KWAVE(NR+1:NQ2+1)  ! +1 because of the interpolated point
      ! re-size wave structure
      if (allocated(KROUTE_out(IENS,JRCH)%KWAVE)) THEN
        deallocate(KROUTE_out(IENS,JRCH)%KWAVE,STAT=IERR)
        if(ierr/=0)then; message=trim(message)//'problem deallocating space for KROUTE_out'; return; endif
      endif
      allocate(KROUTE_out(IENS,JRCH)%KWAVE(0:NN),STAT=IERR)  ! again, the zero element for the last routed point
      if(ierr/=0)then; message=trim(message)//'problem allocating space for KROUTE_out'; return; endif
      ! copy data back to the wave structure and deallocate space for the temporary wave
      KROUTE_out(IENS,JRCH)%KWAVE(0:NN) = NEW_WAVE(0:NN)
      DEALLOCATE(NEW_WAVE,STAT=IERR)
      if(ierr/=0)then; message=trim(message)//'problem deallocating space for NEW_WAVE'; return; endif
    endif  ! (if JRCH is the last reach)

  end subroutine QROUTE_RCH

 ! *********************************************************************
 ! subroutine: extract flow from the reaches upstream of JRCH
 ! *********************************************************************
 subroutine GETUSQ_RCH(IENS,JRCH,LAKEFLAG,T0,T1,ixDesire, & ! input
                       NETOPO_in,RPARAM_in,RCHFLX_in,     & ! input
                       KROUTE_out,                        & ! inout
                       Q_JRCH,TENTRY,T_EXIT,ierr,message, & ! output
                       RSTEP)                               ! optional input
 ! ----------------------------------------------------------------------------------------
 ! Creator(s):
 !   Ross Woods, 2000; Martyn Clark, 2006
 !
 ! ----------------------------------------------------------------------------------------
 ! Purpose:
 !
 !   Used to extract routed flow from the reaches upstream of JRCH, and append to the
 !    non-routed flow in JRCH
 !
 ! ----------------------------------------------------------------------------------------
 ! I/O:
 !
 !   Input(s):
 !       IENS: Ensemble member
 !       JRCH: Index of the downstream reach
 !   LAKEFLAG: >0 means process lakes
 !         T0: Start of the time step
 !         T1: End of the time step
 !  NETOPO_in: river network topology
 !  RPARAM_in: river reach parameter
 !      RSTEP: Retrospective time step
 !
 !      Inout:
 ! KROUTE_out: reach wave data structures
 !
 !    Outputs:
 !  Q_JRCH(:): Vector of merged flow particles in reach JRCH
 !  TENTRY(:): Vector of times flow particles entered reach JRCH (exited upstream reaches)
 !  T_EXIT(:): Vector of times flow particles are expected to exit reach JRCH
 !
 ! ----------------------------------------------------------------------------------------
 ! Future revisions:
 !
 !   (none planned)
 !
 ! ----------------------------------------------------------------------------------------
 USE globalData, only : LKTOPO           ! Lake topology
 USE globalData, only : LAKFLX           ! Lake fluxes
 IMPLICIT NONE
 ! Input
 integer(I4B), intent(in)                 :: IENS         ! ensemble member
 integer(I4B), intent(in)                 :: JRCH         ! reach to process
 integer(I4B), intent(in)                 :: LAKEFLAG     ! >0 if processing lakes
 real(DP),     intent(in)                 :: T0,T1        ! start and end of the time step
 integer(I4B), intent(in)                 :: ixDesire     ! index of the reach for verbose output
 type(RCHTOPO),intent(in),    allocatable :: NETOPO_in(:) ! River Network topology
 type(RCHPRP), intent(in),    allocatable :: RPARAM_in(:) ! River reach parameter
 type(STRFLX), intent(in),    allocatable :: RCHFLX_in(:,:) ! Reach fluxes (ensembles, space [reaches]) for decomposed domains
 integer(I4B), intent(in),    optional    :: RSTEP        ! retrospective time step offset
 ! inout
 type(KREACH), intent(inout), allocatable :: KROUTE_out(:,:) ! reach state data
 ! Output
 REAL(DP),allocatable, intent(out)        :: Q_JRCH(:)    ! merged (non-routed) flow in JRCH
 REAL(DP),allocatable, intent(out)        :: TENTRY(:)    ! time flow particles entered JRCH
 REAL(DP),allocatable, intent(out)        :: T_EXIT(:)    ! time flow is expected to exit JR
 integer(i4b),         intent(out)        :: ierr         ! error code
 character(*),         intent(out)        :: message      ! error message
 ! Local variables to hold the merged inputs to the downstream reach
 INTEGER(I4B)                             :: ROFFSET      ! retrospective offset due to rstep
 REAL(DP)                                 :: DT           ! model time step
 REAL(DP), allocatable                    :: QD(:)        ! merged downstream flow
 REAL(DP), allocatable                    :: TD(:)        ! merged downstream time
 INTEGER(I4B)                             :: ND           ! # points shifted downstream
 INTEGER(I4B)                             :: NJ           ! # points in the JRCH reach
 INTEGER(I4B)                             :: NK           ! # points for routing (NJ+ND)
 INTEGER(I4B)                             :: ILAK         ! lake index
 character(len=strLen)                    :: cmessage     ! error message for downwind routine
 ! initialize error control
 ierr=0; message='GETUSQ_RCH/'
 ! ----------------------------------------------------------------------------------------
 ! (1) EXTRACT (AND MERGE) FLOW FROM UPSTREAM REACHES OR LAKE
 ! ----------------------------------------------------------------------------------------
 ! define dt
 DT = (T1 - T0)
 ! set the retrospective offset
 IF (.NOT.PRESENT(RSTEP)) THEN
   ROFFSET = 0
 ELSE
   ROFFSET = RSTEP
 END IF
 if (LAKEFLAG.EQ.1) then  ! lakes are enabled
  ! get lake outflow and only lake outflow if reach is a lake outlet reach, else do as normal
  ILAK = NETOPO_in(JRCH)%LAKE_IX                              ! lake index
  if (ILAK.GT.0) then                                         ! part of reach is in lake
   if (NETOPO_in(JRCH)%REACHIX.eq.LKTOPO(ILAK)%DREACHI) then  ! we are in a lake outlet reach
    ND = 1
    ALLOCATE(QD(1),TD(1),STAT=IERR)
    if(ierr/=0)then; message=trim(message)//'problem allocating array for QD and TD'; return; endif
    QD(1) = LAKFLX(IENS,ILAK)%LAKE_Q / RPARAM_in(JRCH)%R_WIDTH  ! lake outflow per unit reach width
    TD(1) = T1 - DT*ROFFSET
   else
    call QEXMUL_RCH(IENS,JRCH,T0,T1,ixDesire,     &   ! input
                   NETOPO_in,RPARAM_in,RCHFLX_in, &   ! input
                   KROUTE_out,                    &   ! inout
                   ND,QD,TD,ierr,cmessage,        &   ! output
                   RSTEP)                             ! optional input
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
   endif
  else
   call QEXMUL_RCH(IENS,JRCH,T0,T1,ixDesire,      &   ! input
                   NETOPO_in,RPARAM_in,RCHFLX_in, &   ! input
                   KROUTE_out,                    &   ! inout
                   ND,QD,TD,ierr,cmessage,        &   ! output
                   RSTEP)                             ! optional input
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
  endif
 else  ! lakes disabled
  call QEXMUL_RCH(IENS,JRCH,T0,T1,ixDesire,      &   ! input
                  NETOPO_in,RPARAM_in,RCHFLX_in, &   ! input
                  KROUTE_out,                    &   ! inout
                  ND,QD,TD,ierr,cmessage,        &   ! output
                  RSTEP)                             ! optional input
  if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
  if(JRCH == ixDesire) print*, 'after QEXMUL_RCH: JRCH, ND, QD = ', JRCH, ND, QD
 endif
 ! ----------------------------------------------------------------------------------------
 ! (2) EXTRACT NON-ROUTED FLOW FROM THE REACH JRCH & APPEND TO THE FLOW JUST ROUTED D/S
 ! ----------------------------------------------------------------------------------------
 ! check that the routing structure is associated
 if(allocated(KROUTE_out).eqv..FALSE.)THEN
  ierr=20; message='routing structure KROUTE_out is not associated'; return
 endif
 ! check that the wave has been initialized
 if (allocated(KROUTE_out(IENS,JRCH)%KWAVE).eqv..FALSE.) THEN
  ! if not initialized, then set initial flow to first flow
  ! (this will only occur for a cold start in the case of no streamflow observations)
  allocate(KROUTE_out(IENS,JRCH)%KWAVE(0:0),STAT=IERR)
  if(ierr/=0)then; message=trim(message)//'problem allocating array for KWAVE'; return; endif
  KROUTE_out(IENS,JRCH)%KWAVE(0)%QF = QD(1)
  KROUTE_out(IENS,JRCH)%KWAVE(0)%TI = T0 - DT - DT*ROFFSET
  KROUTE_out(IENS,JRCH)%KWAVE(0)%TR = T0      - DT*ROFFSET
  KROUTE_out(IENS,JRCH)%KWAVE(0)%RF = .TRUE.
 endif
 ! now extract the non-routed flow
 ! NB: routed flows were stripped out in the previous timestep when JRCH was index of u/s reach
 !  {only non-routed flows remain in the routing structure [ + zero element (last routed)]}
 NJ = SIZE(KROUTE_out(IENS,JRCH)%KWAVE) - 1           ! number of elements not routed (-1 for 0)
 NK = NJ + ND                                     ! pts still in reach + u/s pts just routed
 ALLOCATE(Q_JRCH(0:NK),TENTRY(0:NK),T_EXIT(0:NK),STAT=IERR) ! include zero element for INTERP later
 if(ierr/=0)then; message=trim(message)//'problem allocating array for [Q_JRCH, TENTRY, T_EXIT]'; return; endif
 Q_JRCH(0:NJ) = KROUTE_out(IENS,JRCH)%KWAVE(0:NJ)%QF  ! extract the non-routed flow from reach JR
 TENTRY(0:NJ) = KROUTE_out(IENS,JRCH)%KWAVE(0:NJ)%TI  ! extract the non-routed time from reach JR
 T_EXIT(0:NJ) = KROUTE_out(IENS,JRCH)%KWAVE(0:NJ)%TR  ! extract the expected exit time
 Q_JRCH(NJ+1:NJ+ND) = QD(1:ND)                        ! append u/s flow just routed downstream
 TENTRY(NJ+1:NJ+ND) = TD(1:ND)                        ! append u/s time just routed downstream
 T_EXIT(NJ+1:NJ+ND) = -9999.0D0                       ! set un-used T_EXIT to missing
 deallocate(QD,TD,STAT=IERR)                          ! routed flow appended, no longer needed
 if(ierr/=0)then; message=trim(message)//'problem deallocating array for QD and TD'; return; endif

 end subroutine GETUSQ_RCH

 ! *********************************************************************
 ! subroutine: extract flow from multiple reaches and merge into
 !                 a single series
 ! *********************************************************************
 subroutine QEXMUL_RCH(IENS,JRCH,T0,T1,ixDesire,      &   ! input
                       NETOPO_in,RPARAM_in,RCHFLX_in, &   ! input
                       KROUTE_out,                    &   ! inout
                       ND,QD,TD,ierr,message,         &   ! output
                       RSTEP)                             ! optional input
 ! ----------------------------------------------------------------------------------------
 ! Creator(s):
 !   Ross Woods, 2000 (two upstream reaches)
 !   Martyn Clark, 2006 (generalize to multiple upstream reaches, and major code overhaul)
 !
 ! ----------------------------------------------------------------------------------------
 ! Purpose:
 !
 !   Used to extract routed flow from a multiple reaches upstream of JRCH.  Merges flow
 !    from multiple reaches into a single series.
 !
 ! ----------------------------------------------------------------------------------------
 ! I/O:
 !
 !   Input(s):
 !       IENS: Ensemble member
 !       JRCH: Index of the downstream reach
 !         T0: Start of the time step
 !         T1: End of the time step
 !  NETOPO_in: river network topology
 !  RPARAM_in: river reach parameter
 !  RCHFLX_in: reach flux
 !      RSTEP: Retrospective time step
 !
 !      Inout:
 ! KROUTE_out: reach wave data structures
 !
 !   Outputs:
 !      ND   : Number of routed particles
 !      QD(:): Vector of merged flow particles in reach JRCH
 !      TD(:): Vector of times flow particles entered reach JRCH (exited upstream reaches)
 !
 ! ----------------------------------------------------------------------------------------
 ! Future revisions:
 !
 !   (none planned)
 !
 ! ----------------------------------------------------------------------------------------
 IMPLICIT NONE
 ! Input
 INTEGER(i4b), intent(in)                    :: IENS            ! ensemble member
 INTEGER(i4b), intent(in)                    :: JRCH            ! reach to process
 REAL(dp),     intent(in)                    :: T0,T1           ! start and end of the time step
 integer(i4b), intent(in)                    :: ixDesire        ! index of the reach for verbose output
 type(RCHTOPO),intent(in), allocatable       :: NETOPO_in(:)    ! River Network topology
 type(RCHPRP), intent(in), allocatable       :: RPARAM_in(:)    ! River reach parameter
 type(STRFLX), intent(in), allocatable       :: RCHFLX_in(:,:)  ! Reach fluxes (ensembles, space [reaches]) for decomposed domains
 integer(i4b), intent(in), optional          :: RSTEP           ! retrospective time step offset
 ! Inout
 type(KREACH), intent(inout), allocatable    :: KROUTE_out(:,:) ! reach state data
 ! Output
 integer(i4b),          intent(out)          :: ND              ! number of routed particles
 real(dp), allocatable, intent(out)          :: QD(:)           ! flow particles just enetered JRCH
 real(dp), allocatable, intent(out)          :: TD(:)           ! time flow particles entered JRCH
 integer(i4b),          intent(out)          :: ierr            ! error code
 character(*),          intent(out)          :: message         ! error message
 ! Local variables to hold flow/time from upstream reaches
 REAL(DP)                                    :: DT        ! model time step
 INTEGER(I4B)                                :: ROFFSET   ! retrospective offset due to rstep
 INTEGER(I4B)                                :: IUPS      ! loop through u/s reaches
 INTEGER(I4B)                                :: NUPB      ! number of upstream basins
 INTEGER(I4B)                                :: NUPR      ! number of upstream reaches
 INTEGER(I4B)                                :: INDX      ! index of the IUPS u/s reach
 INTEGER(I4B)                                :: MUPR      ! # reaches u/s of IUPS u/s reach
 INTEGER(I4B)                                :: NUPS      ! number of upstream elements
 TYPE(KREACH), allocatable                   :: USFLOW(:) ! waves for all upstream segments
 REAL(DP),     allocatable                   :: UWIDTH(:) ! width of all upstream segments
 INTEGER(I4B)                                :: IMAX      ! max number of upstream particles
 INTEGER(I4B)                                :: IUPR      ! counter for reaches with particles
 INTEGER(I4B)                                :: IR        ! index of the upstream reach
 INTEGER(I4B)                                :: NS        ! size of  the wave
 INTEGER(I4B)                                :: NR        ! # routed particles in u/s reach
 INTEGER(I4B)                                :: NQ        ! NR+1, if non-routed particle exists
 TYPE(FPOINT), allocatable                   :: NEW_WAVE(:)  ! temporary wave
 LOGICAL(LGT)                                :: INIT=.TRUE. ! used to initialize pointers
 ! Local variables to merge flow
 LOGICAL(LGT), DIMENSION(:), ALLOCATABLE     :: MFLG      ! T = all particles processed
 INTEGER(I4B), DIMENSION(:), ALLOCATABLE     :: ITIM      ! processing point for all u/s segments
 REAL(DP), DIMENSION(:), ALLOCATABLE         :: CTIME     ! central time for each u/s segment
 INTEGER(I4B)                                :: JUPS      ! index of reach with the earliest time
 REAL(DP)                                    :: Q_AGG     ! aggregarted flow at a given time
 INTEGER(I4B)                                :: IWAV      ! index of particle in the IUPS reach
 REAL(DP)                                    :: SCFAC     ! scale to conform to d/s reach width
 REAL(DP)                                    :: SFLOW     ! scaled flow at CTIME(JUPS)
 INTEGER(I4B)                                :: IBEG,IEND ! indices for particles that bracket time
 REAL(DP)                                    :: SLOPE     ! slope for the interpolation
 REAL(DP)                                    :: PREDV     ! value predicted by the interpolation
 INTEGER(I4B)                                :: IPRT      ! counter for flow particles
 INTEGER(I4B)                                :: JUPS_OLD  ! check that we don't get stuck in do-forever
 INTEGER(I4B)                                :: ITIM_OLD  ! check that we don't get stuck in do-forever
 REAL(DP)                                    :: TIME_OLD  ! previous time -- used to check for duplicates
 REAL(DP), allocatable                       :: QD_TEMP(:)! flow particles just enetered JRCH
 REAL(DP), allocatable                       :: TD_TEMP(:)! time flow particles entered JRCH
 ! initialize error control
 ierr=0; message='QEXMUL_RCH/'
 ! ----------------------------------------------------------------------------------------
 ! (0) INITIALIZE POINTERS
 ! ----------------------------------------------------------------------------------------
 IF(INIT) THEN
  INIT=.FALSE.
  !deallocate(USFLOW,NEW_WAVE,QD_TEMP,TD_TEMP)
 ENDIF
 ! set the retrospective offset
 IF (.NOT.PRESENT(RSTEP)) THEN
   ROFFSET = 0
 ELSE
   ROFFSET = RSTEP
 END IF
 ! define dt
 DT = (T1 - T0)
 ! ----------------------------------------------------------------------------------------
 ! (1) DETERMINE THE NUMBER OF UPSTREAM REACHES
 ! ----------------------------------------------------------------------------------------
 ! ** SPECIAL CASE ** of no basins with any area
 if(count(NETOPO_in(JRCH)%goodBas)==0)return
 ! Need to extract and merge the runoff from all upstream BASINS as well as the streamflow
 !  from all upstream REACHES.  However, streamflow in headwater basins is undefined.  Thus
 !  the number of series merged from upstream reaches is the number of upstream basins +
 !  the number of upstream reaches that are not headwater basins.
 NUPR = 0                               ! number of upstream reaches
 NUPB = SIZE(NETOPO_in(JRCH)%UREACHI)      ! number of upstream basins
 !NUPB = count(NETOPO_in(JRCH)%goodBas)      ! number of upstream basins
 DO IUPS=1,NUPB
  INDX = NETOPO_in(JRCH)%UREACHI(IUPS)     ! index of the IUPS upstream reach
  !MUPR = SIZE(NETOPO_in(INDX)%UREACHI)     ! # reaches upstream of the IUPS upstream reach
  MUPR = count(NETOPO_in(INDX)%goodBas)     ! # reaches upstream of the IUPS upstream reach
  IF (MUPR.GT.0) NUPR = NUPR + 1        ! reach has streamflow in it, so add that as well
 END DO  ! iups
 NUPS = NUPB + NUPR                     ! number of upstream elements (basins + reaches)
 !print*, 'NUPB, NUPR, NUPS', NUPB, NUPR, NUPS
 !print*, 'NETOPO_in(JRCH)%UREACHK = ', NETOPO_in(JRCH)%UREACHK
 !print*, 'NETOPO_in(JRCH)%goodBas = ', NETOPO_in(JRCH)%goodBas
 ! if nups eq 1, then ** SPECIAL CASE ** of just one upstream basin that is a headwater
 IF (NUPS.EQ.1) THEN
  ND = 1
  ALLOCATE(QD(1),TD(1),STAT=IERR)
  if(ierr/=0)then; message=trim(message)//'problem allocating array QD and TD'; return; endif
  ! get reach index
  IR = NETOPO_in(JRCH)%UREACHI(1)
  ! get flow in m2/s (scaled by with of downstream reach)
  QD(1) = RCHFLX_in(IENS,IR)%BASIN_QR(1)/RPARAM_in(JRCH)%R_WIDTH
  TD(1) = T1
  if(JRCH == ixDesire) print*, 'special case: JRCH, IR, NETOPO_in(IR)%REACHID = ', JRCH, IR, NETOPO_in(IR)%REACHID
  RETURN
 ENDIF
 ! allocate space for the upstream flow, time, and flags
 ALLOCATE(USFLOW(NUPS),UWIDTH(NUPS),CTIME(NUPS),STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem allocating arrays [USFLOW, UWIDTH, CTIME]'; return; endif
 ! define the minimum size of the routed data structure (number of flow particles)
 !  (IMAX is increased when looping through the reaches -- section 3 below)
 IMAX = NUPB                            ! flow from basins (one particle / timestep)
 ! ----------------------------------------------------------------------------------------
 ! (2) EXTRACT FLOW FROM UPSTREAM BASINS
 ! ----------------------------------------------------------------------------------------
 DO IUPS=1,NUPB
  ! identify the index for the IUPS upstream segment
  IR = NETOPO_in(JRCH)%UREACHI(IUPS)
  ! allocate space for the IUPS stream segment (flow, time, and flags)
  ALLOCATE(USFLOW(IUPS)%KWAVE(0:1),STAT=IERR)  ! basin, has flow @start and @end of the time step
  if(ierr>0)then; message=trim(message)//'problem allocating array USFLOW(IUPS)%KWAVE'; return; endif
  ! place flow and time in the KWAVE array (routing done with time-delay histogram in TIMDEL_BAS.F90)
  USFLOW(IUPS)%KWAVE(0:1)%QF = RCHFLX_in(IENS,IR)%BASIN_QR(0:1)      ! flow
  USFLOW(IUPS)%KWAVE(0:1)%TI = (/T0,T1/) - DT*ROFFSET                 ! entry time (not used)
  USFLOW(IUPS)%KWAVE(0:1)%TR = (/T0,T1/) - DT*ROFFSET                 ! exit time
  USFLOW(IUPS)%KWAVE(0:1)%RF = .TRUE.                                 ! routing flag
  !write(*,'(a,i4,1x,2(e20.10,1x))') 'IR, USFLOW(IUPS)%KWAVE(0:1)%QF = ', IR, USFLOW(IUPS)%KWAVE(0:1)%QF
  ! save the upstream width
  UWIDTH(IUPS) = 1.0D0                         ! basin = unit width
  ! save the the time for the first particle in each reach
  CTIME(IUPS) = USFLOW(IUPS)%KWAVE(1)%TR       ! central time
 END DO    ! (loop through upstream basins)
 ! ----------------------------------------------------------------------------------------
 ! (3) EXTRACT FLOW FROM UPSTREAM REACHES
 ! ----------------------------------------------------------------------------------------
 IUPR = 0
 DO IUPS=1,NUPB
  INDX = NETOPO_in(JRCH)%UREACHI(IUPS)     ! index of the IUPS upstream reach
  !MUPR = SIZE(NETOPO_in(INDX)%UREACHI)     ! # reaches upstream of the IUPS upstream reach
  MUPR = count(NETOPO_in(INDX)%goodBas)     ! # reaches upstream of the IUPS upstream reach
  IF (MUPR.GT.0) THEN                   ! reach has streamflow in it, so add that as well
   IUPR = IUPR + 1
   ! identify the index for the IUPS upstream segment
   IR = NETOPO_in(JRCH)%UREACHI(IUPS)
   ! identify the size of the wave
   NS = SIZE(KROUTE_out(IENS,IR)%KWAVE)
   ! identify number of routed flow elements in the IUPS upstream segment
   NR = COUNT(KROUTE_out(IENS,IR)%KWAVE(:)%RF)
   ! include a non-routed point, if it exists
   NQ = MIN(NR+1,NS)
   ! allocate space for the IUPS stream segment (flow, time, and flags)
   ALLOCATE(USFLOW(NUPB+IUPR)%KWAVE(0:NQ-1),STAT=IERR)  ! (zero position = last routed)
   if(ierr/=0)then; message=trim(message)//'problem allocating array USFLOW(NUPB+IUPR)%KWAVE(0:NQ-1)'; return; endif
   ! place data in the new arrays
   USFLOW(NUPB+IUPR)%KWAVE(0:NQ-1) = KROUTE_out(IENS,IR)%KWAVE(0:NQ-1)
   ! here a statement where we check for a modification in the upstream reach;
   ! if flow upstream is modified, then copy KROUTE_out(:,:)%KWAVE(:)%QM to USFLOW(..)%KWAVE%QF
   !IF (NUSER.GT.0.AND.SIMDAT%UCFFLAG.GE.1) THEN !if the irrigation module is active and there are users
   !  IF (RCHFLX_out(IENS,IR)%TAKE.GT.0._DP) THEN !if take from upstream reach is greater then zero
   !    ! replace QF with modified flow (as calculated in extract_from_rch)
   !    USFLOW(NUPB+IUPR)%KWAVE(0:NQ-1)%QF = KROUTE_out(IENS,IR)%KWAVE(0:NQ-1)%QM
   !  ENDIF
   !ENDIF
   ! ...and REMOVE the routed particles from the upstream reach
   ! (copy the wave to a temporary wave)
   IF (allocated(NEW_WAVE)) THEN
     DEALLOCATE(NEW_WAVE,STAT=IERR)    ! (so we can allocate)
     if(ierr/=0)then; message=trim(message)//'problem deallocating array NEW_WAVE'; return; endif
   END IF
   ALLOCATE(NEW_WAVE(0:NS-1),STAT=IERR)                 ! get new wave
   if(ierr/=0)then; message=trim(message)//'problem allocating array NEW_WAVE'; return; endif
   NEW_WAVE(0:NS-1) = KROUTE_out(IENS,IR)%KWAVE(0:NS-1)  ! copy

   ! (re-size wave structure)
   IF (.NOT.allocated(KROUTE_out(IENS,IR)%KWAVE))then; print*,' not allocated. in qex ';return; endif
   IF (allocated(KROUTE_out(IENS,IR)%KWAVE)) THEN
     deallocate(KROUTE_out(IENS,IR)%KWAVE,STAT=IERR)
     if(ierr/=0)then; message=trim(message)//'problem deallocating array KROUTE_out'; return; endif
   END IF
   ALLOCATE(KROUTE_out(IENS,IR)%KWAVE(0:NS-NR),STAT=IERR)   ! reduced size
   if(ierr/=0)then; message=trim(message)//'problem allocating array KROUTE_out'; return; endif

   ! (copy "last routed" and "non-routed" elements)
   KROUTE_out(IENS,IR)%KWAVE(0:NS-NR) = NEW_WAVE(NR-1:NS-1)

   ! (de-allocate temporary wave)
   DEALLOCATE(NEW_WAVE,STAT=IERR)
   if(ierr/=0)then; message=trim(message)//'problem deallocating array NEW_WAVE'; return; endif

   ! save the upstream width
   UWIDTH(NUPB+IUPR) = RPARAM_in(IR)%R_WIDTH            ! reach, width = parameter
   ! save the time for the first particle in each reach
   CTIME(NUPB+IUPR) = USFLOW(NUPB+IUPR)%KWAVE(1)%TR  ! central time

   ! keep track of the total number of points that must be routed downstream
   IMAX = IMAX + (NR-1)     ! exclude zero point for the last routed
  ENDIF ! if reach has particles in it
 END DO  ! iups
 ! ----------------------------------------------------------------------------------------
 ! (4) MERGE FLOW FROM MULTIPLE UPSTREAM REACHES
 ! ----------------------------------------------------------------------------------------
 ! This is a bit tricky.  Consider a given upstream reach x.  For all upstream reaches
 !  *other than* x, we need to estimate (interpolate) flow for the *times* associted with
 !  each of the flow particles in reach x.  Then, at a given time, we can sum the flow
 !  (routed in reach x plus interpolated flow in all other reaches).  This needs to be done
 !  for all upstream reaches.
 ! ----------------------------------------------------------------------------------------
 ! We accomplish this as follows.  We define a vector of indices (ITIM), where each
 !  element of ITIM points to a particle in a given upstream reach still to be processed.
 !  We also define a vector of times (CTIME), which is the time of the flow particles that
 !  relate to the vector of indices ITIM.  We identify upstream reach with the earliest
 !  time in CTIME, save the flow, and produce corresponding flow estimates for the same
 !  time in all other reaches.  We then scale the flow and flow estimates in all upstream
 !  reaches by the width of the downstream reach, and sum the flow over all upstream reaches.
 !  We then move the index forward in ITIM (for the upstream reach just processed), get a
 !  new vector CTIME, and process the next earliest particle.  We continue until all
 !  flow particles are processed in all upstream reaches.
 ! ----------------------------------------------------------------------------------------
 IPRT = 0  ! initialize counter for flow particles in the output array
 ! allocate space for the merged flow at the downstream reach
 ALLOCATE(QD_TEMP(IMAX),TD_TEMP(IMAX),STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem allocating arrays [QD_TEMP, TD_TEMP]'; return; endif
 ! allocate positional arrays
 ALLOCATE(MFLG(NUPS),ITIM(NUPS),STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem allocating arrays [MFLG, ITIM]'; return; endif
 ! initalize the flag that defines whether all particles in a given reach are processed
 MFLG(1:NUPS)  = .FALSE.                     ! false until all particles are processed
 ! initialize the search vector
 ITIM(1:NUPS)  = 1                           ! start with the first element of the wave
 ! initialize jups_old and itim_old (used to check we don't get stuck in the do-forever loop)
 JUPS_OLD = HUGE(JUPS_OLD)
 ITIM_OLD = HUGE(ITIM_OLD)
 DO      ! loop through all the times in the upstream reaches until no more routed flows
  ! find the reach with the earliest time in all upstream reaches
  !  (NB: the time at the start of the timestep is the earliest possible time and
  !       the time at the end of the timestep is the latest possible time)
  JUPS  = MINLOC(CTIME,DIM=1)     ! JUPS = reach w/ earliest time
  ! check that we're not stuck in a continuous do loop
  IF (JUPS.EQ.JUPS_OLD .AND. ITIM(JUPS).EQ.ITIM_OLD) THEN
   ierr=20; message=trim(message)//'stuck in the continuous do-loop'; return
  ENDIF
  ! save jups and itim(jups) to check that we don't get stuck in a continuous do-loop
  JUPS_OLD = JUPS
  ITIM_OLD = ITIM(JUPS)
  ! check that there are still particles in the given reach that require processing
  IF (.NOT.MFLG(JUPS)) THEN
   ! check that the particle in question is a particle routed (if not, then don't process)
   IF (USFLOW(JUPS)%KWAVE(ITIM(JUPS))%RF.EQV..FALSE.) THEN
    MFLG(JUPS) = .TRUE. ! if routing flag is false, then have already processed all particles
    CTIME(JUPS) = HUGE(SFLOW)  ! largest possible number = ensure reach is not selected again
   ! the particle is in need of processing
   ELSE
    ! define previous time
    IF (IPRT.GE.1) THEN
      TIME_OLD = TD_TEMP(IPRT)
    ELSE ! (if no particles, set to largest possible negative number)
      TIME_OLD = -HUGE(SFLOW)
    END IF
    ! check that the particles are being processed in the correct order
    IF (CTIME(JUPS).LT.TIME_OLD) THEN
     ierr=30; message=trim(message)//'expect process in order of time'; return
    ENDIF
    ! don't process if time already exists
    IF (CTIME(JUPS).NE.TIME_OLD) THEN
     ! -------------------------------------------------------------------------------------
     ! compute sum of scaled flow for all reaches
     Q_AGG = 0.0D0
     DO IUPS=1,NUPS
      ! identify the element of the wave for the IUPS upstream reach
      IWAV = ITIM(IUPS)
      ! compute scale factor (scale upstream flow by width of downstream reach)
      SCFAC = UWIDTH(IUPS) / RPARAM_in(JRCH)%R_WIDTH
      ! case of the upstream reach with the minimum time (no interpolation required)
      IF (IUPS.EQ.JUPS) THEN
       SFLOW = USFLOW(IUPS)%KWAVE(IWAV)%QF * SCFAC  ! scaled flow
      ! case of all other upstream reaches (*** now, interpolate ***)
      ELSE
       ! identify the elements that bracket the flow particle in the reach JUPS
       ! why .GE.?  Why not .GT.??
       IBEG = IWAV; IF (USFLOW(IUPS)%KWAVE(IBEG)%TR.GE.CTIME(JUPS)) IBEG=IWAV-1
       IEND = IBEG+1  ! *** check the elements are ordered as we think ***
       ! test if we have bracketed properly
       IF (USFLOW(IUPS)%KWAVE(IEND)%TR.LT.CTIME(JUPS) .OR. &
           USFLOW(IUPS)%KWAVE(IBEG)%TR.GT.CTIME(JUPS)) THEN
            ierr=40; message=trim(message)//'the times are not ordered as we assume'; return
       ENDIF  ! test for bracketing
       ! estimate flow for the IUPS upstream reach at time CTIME(JUPS)
       SLOPE = (USFLOW(IUPS)%KWAVE(IEND)%QF - USFLOW(IUPS)%KWAVE(IBEG)%QF) / &
               (USFLOW(IUPS)%KWAVE(IEND)%TR - USFLOW(IUPS)%KWAVE(IBEG)%TR)
       PREDV =  USFLOW(IUPS)%KWAVE(IBEG)%QF + SLOPE*(CTIME(JUPS)-USFLOW(IUPS)%KWAVE(IBEG)%TR)
       SFLOW = PREDV * SCFAC  ! scaled flow
      ENDIF  ! (if interpolating)
      ! aggregate flow
      Q_AGG = Q_AGG + SFLOW
     END DO  ! looping through upstream elements
     ! -------------------------------------------------------------------------------------
     ! place Q_AGG and CTIME(JUPS) in the output arrays
     IPRT = IPRT + 1
     QD_TEMP(IPRT) = Q_AGG
     TD_TEMP(IPRT) = CTIME(JUPS)
    ENDIF  ! (check that time doesn't already exist)
    ! check if the particle just processed is the last element
    IF (ITIM(JUPS).EQ.SIZE(USFLOW(JUPS)%KWAVE)-1) THEN  ! -1 because of the zero element
     MFLG(JUPS) = .TRUE.            ! have processed all particles in a given u/s reach
     CTIME(JUPS) = HUGE(SFLOW)      ! largest possible number = ensure reach is not selected again
    ELSE
     ITIM(JUPS) = ITIM(JUPS) + 1                       ! move on to the next flow element
     CTIME(JUPS) = USFLOW(JUPS)%KWAVE(ITIM(JUPS))%TR   ! save the time
    ENDIF  ! (check if particle is the last element)
   ENDIF  ! (check if the particle is a routed element)
  ENDIF  ! (check that there are still particles to process)
  ! if processed all particles in all upstream reaches, then EXIT
  IF (COUNT(MFLG).EQ.NUPS) EXIT
 END DO   ! do-forever
 ! free up memory
 DO IUPS=1,NUPS  ! de-allocate each element of USFLOW
  DEALLOCATE(USFLOW(IUPS)%KWAVE,STAT=IERR)
  if(ierr/=0)then; message=trim(message)//'problem deallocating array USFLOW(IUPS)%KWAVE'; return; endif
 END DO          ! looping thru elements of USFLOW
 DEALLOCATE(USFLOW,UWIDTH,CTIME,ITIM,MFLG,STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem deallocating arrays [USFLOW, UWIDTH, CTIME, ITIM, MFLG]'; return; endif
 ! ...and, save reduced arrays in QD and TD
 ND = IPRT
 ALLOCATE(QD(ND),TD(ND),STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem allocating arrays [QD, TD]'; return; endif
 QD(1:ND) = QD_TEMP(1:ND)
 TD(1:ND) = TD_TEMP(1:ND)
 DEALLOCATE(QD_TEMP,TD_TEMP,STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem deallocating arrays [QD_TEMP, TD_TEMP]'; return; endif

 end subroutine QEXMUL_RCH

 ! *********************************************************************
 !  subroutine: removes flow particles from the routing structure,
 !                 to reduce memory usage and processing time
 ! *********************************************************************
 subroutine REMOVE_RCH(MAXQPAR,&                           ! input
                       Q_JRCH,TENTRY,T_EXIT,ierr,message)  ! output
 ! ----------------------------------------------------------------------------------------
 ! Creator(s):
 !   Martyn Clark, 2006
 !
 ! ----------------------------------------------------------------------------------------
 ! Purpose:
 !
 !   Used to remove flow particles from the routing structure, to decrease memory usage
 !    and processing time
 !
 ! ----------------------------------------------------------------------------------------
 ! I/O:
 !
 !  Q_JRCH(:): Vector of merged flow particles in reach JRCH
 !  TENTRY(:): Vector of times flow particles entered reach JRCH (exited upstream reaches)
 !  T EXIT(:): Vector of times flow particles are EXPECTED to exit reach JRCH
 !
 ! ----------------------------------------------------------------------------------------
 ! Future revisions:
 !
 !   (none planned)
 !
 ! ----------------------------------------------------------------------------------------
 IMPLICIT NONE
 ! Input
 INTEGER(I4B),          INTENT(IN)           :: MAXQPAR  ! maximum number of flow particles allowed
 ! output
 REAL(DP), allocatable, intent(inout)        :: Q_JRCH(:)! merged (non-routed) flow in JRCH
 REAL(DP), allocatable, intent(inout)        :: TENTRY(:)! time flow particles entered JRCH
 REAL(DP), allocatable, intent(inout)        :: T_EXIT(:)! time flow particles exited JRCH
 integer(i4b),          intent(out)          :: ierr     ! error code
 character(*),          intent(out)          :: message  ! error message
 ! Local variables
 INTEGER(I4B)                                :: NPRT     ! number of flow particles
 INTEGER(I4B)                                :: IPRT     ! loop through flow particles
 REAL(DP), DIMENSION(:), ALLOCATABLE         :: Q,T,Z    ! copies of Q_JRCH and T_JRCH
 LOGICAL(LGT), DIMENSION(:), ALLOCATABLE     :: PARFLG   ! .FALSE. if particle removed
 INTEGER(I4B), DIMENSION(:), ALLOCATABLE     :: INDEX0   ! indices of original vectors
 REAL(DP), DIMENSION(:), ALLOCATABLE         :: ABSERR   ! absolute error btw interp and orig
 REAL(DP)                                    :: Q_INTP   ! interpolated particle
 INTEGER(I4B)                                :: MPRT     ! local number of flow particles
 INTEGER(I4B), DIMENSION(:), ALLOCATABLE     :: INDEX1   ! indices of particles retained
 REAL(DP), DIMENSION(:), ALLOCATABLE         :: E_TEMP   ! temp abs error btw interp and orig
 INTEGER(I4B), DIMENSION(1)                  :: ITMP     ! result of minloc function
 INTEGER(I4B)                                :: ISEL     ! index of local minimum value
 INTEGER(I4B)                                :: INEG     ! lower boundary for interpolation
 INTEGER(I4B)                                :: IMID     ! desired point for interpolation
 INTEGER(I4B)                                :: IPOS     ! upper boundary for interpolation
 ! initialize error control
 ierr=0; message='REMOVE_RCH/'
 ! ----------------------------------------------------------------------------------------
 ! (1) INITIALIZATION
 ! ----------------------------------------------------------------------------------------
 ! get the number of particles
 NPRT = SIZE(Q_JRCH)-1                       ! -1 because of zero element
 ! allocate and initialize arrays
 ALLOCATE(Q(0:NPRT),T(0:NPRT),Z(0:NPRT),PARFLG(0:NPRT),INDEX0(0:NPRT),ABSERR(0:NPRT),STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem allocating arrays [Q, T, Z, PARFLG, INDEX0, ABSERR]'; return; endif
 Q = Q_JRCH; T = TENTRY     ! get copies of Q_JRCH and TENTRY
 Z = T_EXIT                 ! (not used in the interp, but include for consistency)
 PARFLG = .TRUE.            ! particle flag = start with all points
 INDEX0 = arth(0,1,NPRT+1)  ! index = (0,1,2,...,NPRT)
 ABSERR = HUGE(Q)           ! largest possible double-precision number
 ! get the absolte difference between actual points and interpolated points
 DO IPRT=1,NPRT-1
  ! interpolate at point (iprt)
  Q_INTP = INTERP(T(IPRT),Q(IPRT-1),Q(IPRT+1),T(IPRT-1),T(IPRT+1))
  ! save the absolute difference between the actual value and the interpolated value
  ABSERR(IPRT) = ABS(Q_INTP-Q(IPRT))
 END DO
 ! ----------------------------------------------------------------------------------------
 ! (2) REMOVAL
 ! ----------------------------------------------------------------------------------------
 DO  ! continue looping until the number of particles is below the limit
  ! get the number of particles still in the structure
  MPRT = COUNT(PARFLG)-1       ! -1 because of the zero element
  ! get a copy of (1) indices of selected points, and (2) the interpolation errors
  ALLOCATE(INDEX1(0:MPRT),E_TEMP(0:MPRT),STAT=IERR)
  if(ierr/=0)then; message=trim(message)//'problem allocating arrays [INDEX1, E_TEMP]'; return; endif
  INDEX1 = PACK(INDEX0,PARFLG) ! (restrict attention to the elements still present)
  E_TEMP = PACK(ABSERR,PARFLG)
  ! check for exit condition (exit after "pack" b.c. indices used to construct final vectors)
  IF (MPRT.LT.MAXQPAR) EXIT
  ! get the index of the minimum value
  ITMP = MINLOC(E_TEMP)
  ISEL = LBOUND(E_TEMP,DIM=1) + ITMP(1) - 1 ! MINLOC assumes count from 1, here (0,1,2,...NPRT)
  ! re-interpolate the point immediately before the point flagged for removal
  IF (INDEX1(ISEL-1).GT.0) THEN
   INEG=INDEX1(ISEL-2); IMID=INDEX1(ISEL-1); IPOS=INDEX1(ISEL+1)
   Q_INTP = INTERP(T(IMID),Q(INEG),Q(IPOS),T(INEG),T(IPOS))
   ABSERR(IMID) = ABS(Q_INTP-Q(IMID))
  ENDIF
  ! re-interpolate the point immediately after the point flagged for removal
  IF (INDEX1(ISEL+1).LT.NPRT) THEN
   INEG=INDEX1(ISEL-1); IMID=INDEX1(ISEL+1); IPOS=INDEX1(ISEL+2)
   Q_INTP = INTERP(T(IMID),Q(INEG),Q(IPOS),T(INEG),T(IPOS))
   ABSERR(IMID) = ABS(Q_INTP-Q(IMID))
  ENDIF
  ! flag the point as "removed"
  PARFLG(INDEX1(ISEL)) = .FALSE.
  ! de-allocate arrays
  DEALLOCATE(INDEX1,E_TEMP,STAT=IERR)
  if(ierr/=0)then; message=trim(message)//'problem deallocating arrays [INDEX1, E_TEMP]'; return; endif
 END DO  ! keep looping until a sufficient number of points are removed
 ! ----------------------------------------------------------------------------------------
 ! (3) RE-SIZE DATA STRUCTURES
 ! ----------------------------------------------------------------------------------------
 DEALLOCATE(Q_JRCH,TENTRY,T_EXIT,STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem deallocating arrays [Q_JRCH, TENTRY, T_EXIT]'; return; endif
 ALLOCATE(Q_JRCH(0:MPRT),TENTRY(0:MPRT),T_EXIT(0:MPRT),STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem allocating arrays [Q_JRCH, TENTRY, T_EXIT]'; return; endif
 Q_JRCH = Q(INDEX1)
 TENTRY = T(INDEX1)
 T_EXIT = Z(INDEX1)
 DEALLOCATE(INDEX1,E_TEMP,STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem deallocating arrays [INDEX1, E_TEMP]'; return; endif
 DEALLOCATE(Q,T,Z,PARFLG,ABSERR,INDEX0,STAT=IERR)
 if(ierr/=0)then; message=trim(message)//'problem deallocating arrays [Q, T, Z, PARFLG, INDEX0, ABSERR]'; return; endif

 contains

  function INTERP(T0,Q1,Q2,T1,T2)
    REAL(DP),INTENT(IN)                        :: Q1,Q2  ! flow at neighbouring times
    REAL(DP),INTENT(IN)                        :: T1,T2  ! neighbouring times
    REAL(DP),INTENT(IN)                        :: T0     ! desired time
    REAL(DP)                                   :: INTERP ! function name
    INTERP = Q1 + ( (Q2-Q1) / (T2-T1) ) * (T0-T1)
  end function INTERP

 end subroutine

 ! *********************************************************************
 ! new subroutine: calculate the propagation of kinematic waves in a
 !                 single stream segment, including the formation and
 !                 propagation of a kinematic shock
 ! *********************************************************************
 subroutine KINWAV_RCH(JRCH,T_START,T_END,ixDesire,               & ! input: location and time
                       NETOPO_in, RPARAM_in,                      & ! input: river data structure
                       Q_JRCH,TENTRY,T_EXIT,FROUTE,               & ! inout: kwt states
                       NQ2,                                       & ! output:
                       ierr,message)
 ! ----------------------------------------------------------------------------------------
 ! Creator(s):
 !   Derek Goring, 1994; modified by Ross Woods, 2002
 !   Martyn Clark, 2006: complete overhaul
 !   Martyn Clark, 2012: extract to stand-alone model
 !
 ! ----------------------------------------------------------------------------------------
 ! Purpose:
 !
 !   Used to calculate the propagation of kinematic waves in an individual stream
 !   segment, including the formation and propagation of a kinematic shock.
 !
 ! ----------------------------------------------------------------------------------------
 ! I/O:
 !
 !   Input(s):
 !   ---------
 !      JRCH: index of reach processed
 !   T_START: start of the time step
 !     T_END: end of the time step
 !    Q_JRCH: array of flow elements -- neighbouring times are merged if a shock forms, but
 !                                      then merged flows are dis-aggregated to save the
 !                                      flow either side of a shock -- thus we may have
 !                                      fewer elements on output if several particles are
 !                                      merged, INTENT(INOUT)
 !    TENTRY: array of time elements -- neighbouring times are merged if a shock forms,
 !                                      then merged times are dis-aggregated, one second is
 !                                      added to the time corresponding to the higer merged
 !                                      flow (note also fewer elements), INTENT(INOUT)
 !
 !   Outputs:
 !   --------
 !    FROUTE: array of routing flags -- All inputs are .FALSE., but flags change to .TRUE.
 !                                      if element is routed INTENT(OUT)
 !    T_EXIT: array of time elements -- identify the time each element is EXPECTED to exit
 !                                      the stream segment, INTENT(OUT).  Used in INTERPTS
 !       NQ2: number of particles    -- <= input becuase multiple particles may merge
 !
 ! ----------------------------------------------------------------------------------------
 ! Method:
 !
 !   Flow routing through an individual stream segment is performed using the method
 !   described by Goring (1994).  For each wave in the stream segment, Goring's
 !   method calculates the celerity (m/s) and travel time, length/celerity (s).  If
 !   the initial time of the wave plus the travel time is less than the time at the
 !   end of a time step, then the wave is routed to the end of the stream segment and
 !   the time stamp is updated.  Otherwise, the wave remains in the stream segment
 !   and the time stamp remains constant.  In this context "earlier" times imply that
 !   a kinematic shock is located nearer the downstream end of a stream segment.
 !
 !   A decrease in the time between kinematic waves deceases eventually produces a
 !   discontinuity known as a kinematic shock.  When this occurs the kinematic waves
 !   are merged and the celerity is modified.  See Goring (1994) for more details.
 !
 ! ----------------------------------------------------------------------------------------
 ! Source:
 !
 !   This routine is based on the subroutine kinwav, located in kinwav_v7.f
 !
 ! ----------------------------------------------------------------------------------------
 ! Modifications to source (mclark@ucar.edu):
 !
 !   * All variables are now defined (IMPLICIT NONE) and described (comments)
 !
 !   * Parameters are defined within the subroutine (for ease of readibility)
 !
 !   * Added many comments
 !
 !   * Replaced GOTO statements with DO-CYCLE loops and DO-FOREVER loops with EXIT clause
 !      (for ease of readability), and replaced some do-continue loops w/ array operations
 !      and use F90 dynamic memory features
 !
 ! ----------------------------------------------------------------------------------------
 ! Future revisions:
 !
 !   (none planned)
 !
 ! ----------------------------------------------------------------------------------------
 IMPLICIT NONE
 ! Input
 integer(i4b), intent(in)                    :: JRCH     ! Reach to process
 real(dp),     intent(in)                    :: T_START  ! start of the time step
 real(dp),     intent(in)                    :: T_END    ! end of the time step
 integer(i4b), intent(in)                    :: ixDesire ! index of the reach for verbose output
 type(RCHTOPO),intent(in),    allocatable    :: NETOPO_in(:)    ! River Network topology
 type(RCHPRP), intent(in),    allocatable    :: RPARAM_in(:)    ! River reach parameter
 ! Input/Output
 REAL(dp),     intent(inout)                 :: Q_JRCH(:)! flow to be routed
 REAL(dp),     intent(inout)                 :: TENTRY(:)! time to be routed
 REAL(dp),     intent(inout)                 :: T_EXIT(:)! time pts expected exit segment
 logical(lgt), intent(inout)                 :: FROUTE(:)! routing flag, T=routed
 ! Output
 integer(i4b), intent(out)                   :: NQ2      ! # particles (<= input b/c merge)
 integer(i4b), intent(out)                   :: ierr     ! error code
 character(*), intent(out)                   :: message  ! error message
 ! Internal
 REAL(DP)                                    :: ALFA     ! constant, 5/3
 REAL(DP)                                    :: K        ! sqrt(slope)/mannings N
 REAL(DP)                                    :: XMX      ! length of the stream segment
 INTEGER(I4B)                                :: NN       ! number of input points
 INTEGER(I4B)                                :: NI       ! original size of the input
 INTEGER(I4B)                                :: NM       ! mumber of merged elements
 INTEGER(I4B), DIMENSION(SIZE(Q_JRCH))       :: IX       ! minimum index of each merged element
 INTEGER(I4B), DIMENSION(SIZE(Q_JRCH))       :: MF       ! index for input element merged
 REAL(DP), DIMENSION(SIZE(Q_JRCH))           :: T0,T1,T2 ! copy of input time
 REAL(DP), DIMENSION(SIZE(Q_JRCH))           :: Q0,Q1,Q2 ! flow series
 REAL(DP), DIMENSION(SIZE(Q_JRCH))           :: WC       ! wave celerity
 INTEGER(I4B)                                :: IW,JW    ! looping variables, break check
 REAL(DP)                                    :: X,XB     ! define smallest, biggest shock
 REAL(DP)                                    :: WDIFF    ! difference in wave celerity-1
 REAL(DP)                                    :: XXB      ! wave break
 INTEGER(I4B)                                :: IXB,JXB  ! define position of wave break
 REAL(DP)                                    :: A1,A2    ! stage - different sides of break
 REAL(DP)                                    :: CM       ! merged celerity
 REAL(DP)                                    :: TEXIT    ! expected exit time of "current" particle
 REAL(DP)                                    :: TNEXT    ! expected exit time of "next" particle
 REAL(DP)                                    :: TEXIT2   ! exit time of "bottom" of merged element
 INTEGER(I4B)                                :: IROUTE   ! looping variable for routing
 INTEGER(I4B)                                :: JROUTE   ! looping variable for routing
 INTEGER(I4B)                                :: ICOUNT   ! used to account for merged pts
 character(len=strLen)                       :: cmessage ! error message of downwind routine
 ! ----------------------------------------------------------------------------------------
 ! NOTE: If merged particles DO NOT exit the reach in the current time step, they are
 !       disaggregated into the original particles; if the merged particles DO exit the
 !       reach, then we save only the "slowest" and "fastest" particle.
 ! ----------------------------------------------------------------------------------------
 !       To disaggregate particles we need to keep track of the output element for which
 !       each input element is merged. This is done using the integer vector MF:  If, for
 !       example, MF = (1,2,2,2,3,4,5,5,5,5,6,7,8), this means the 2nd, 3rd, and 4th input
 !       particles have been merged into the 2nd particle of the output, and that the 7th,
 !       8th, 9th, and 10th input particles have been merged into the 5th particle of the
 !       output.  We only store the "slowest" and "fastest" particle within the merged set.
 ! ----------------------------------------------------------------------------------------
 !       Disaggregating the particles proceeds as follows:  If particles have been merged,
 !       then the flow in Q1 will be different from the flow in Q2, that is, continuing with
 !       the above example, Q1(IROUTE).NE.Q2(IROUTE), where IROUTE = 2 or 5.  In the case of
 !       a merged particle we identify all elements of MF that are equal to IROUTE (that is,
 !       the 2nd, 3rd, and 4th elements of MF = 2), populate the output vector with the
 !       selected elements (2,3,4) of the input vector.
 ! ----------------------------------------------------------------------------------------
 ! initialize error control
 ierr=0; message='KINWAV_RCH/'
 ! Get the reach parameters
 ALFA = 5._dp/3._dp        ! should this be initialized here or in a parameter file?
 K    = SQRT(RPARAM_in(JRCH)%R_SLOPE)/RPARAM_in(JRCH)%R_MAN_N
 XMX  = RPARAM_in(JRCH)%RLENGTH
 ! Identify the number of points to route
 NN = SIZE(Q1)                                ! modified when elements are merged
 NI = NN                                      ! original size of the input
 IF(NN.EQ.0) RETURN                           ! don't do anything if no points in the reach
 ! Initialize the vector that indicates which output element the input elements are merged
 MF = arth(1,1,NI)                            ! Num. Rec. intrinsic: see MODULE nrutil.f90
 ! Initialize the vector that indicates the minumum index of each merged element
 IX = arth(1,1,NI)                            ! Num. Rec. intrinsic: see MODULE nrutil.f90
 ! Get copies of the flow/time particles
 Q0=Q_JRCH; Q1=Q_JRCH; Q2=Q_JRCH
 T0=TENTRY; T1=TENTRY; T2=TENTRY
 ! compute wave celerity for all flow points (array operation)
 WC(1:NN) = ALFA*K**(1./ALFA)*Q1(1:NN)**((ALFA-1.)/ALFA)
 ! check
 if(jRch==ixDesire) print*, 'q1(1:nn), wc(1:nn), RPARAM_in(JRCH)%R_SLOPE, nn = ', &
                            q1(1:nn), wc(1:nn), RPARAM_in(JRCH)%R_SLOPE, nn

 ! handle breaking waves
 GT_ONE: IF(NN.GT.1) THEN                     ! no breaking if just one point
  X = 0.                                      ! altered later to describe "closest" shock
  GOTALL: DO                                  ! keep going until all shocks are merged
   XB = XMX                                   ! initialized to length of the stream segment
   ! --------------------------------------------------------------------------------------
   ! check for breaking
   ! --------------------------------------------------------------------------------------
   WCHECK: DO IW=2,NN
    JW=IW-1
    IF(WC(IW).EQ.0. .OR. WC(JW).EQ.0.) CYCLE  ! waves not moving
    WDIFF = 1./WC(JW) - 1./WC(IW)             ! difference in wave celerity
    IF(WDIFF.EQ.0.) CYCLE                     ! waves moving at the same speed
    IF(WC(IW).EQ.WC(JW)) CYCLE                ! identical statement to the above?
    XXB = (T1(IW)-T1(JW)) / WDIFF             ! XXB is point of breaking in x direction
    IF(XXB.LT.X .OR. XXB.GT.XB) CYCLE         ! XB init at LENGTH, so > XB do in next reach
    ! if get to here, the wave is breaking
    XB  = XXB                                 ! identify break "closest to upstream" first
    IXB = IW
   END DO WCHECK
   ! --------------------------------------------------------------------------------------
   IF(XB.EQ.XMX) EXIT                         ! got all breaking waves, exit gotall
   ! --------------------------------------------------------------------------------------
   ! combine waves
   ! --------------------------------------------------------------------------------------
   NN  = NN-1
   JXB = IXB-1                                ! indices for the point of breaking
   NM  = NI-NN                                ! number of merged elements
   ! calculate merged shockwave celerity (CM) using finite-difference approximation
   Q2(JXB) =MAX(Q2(JXB),Q2(IXB))              ! flow of largest merged point
   Q1(JXB) =MIN(Q1(JXB),Q1(IXB))              ! flow of smallest merged point
   A2 = (Q2(JXB)/K)**(1./ALFA)                ! Q = (1./MAN_N) H**(ALFA) sqrt(SLOPE)
   A1 = (Q1(JXB)/K)**(1./ALFA)                ! H = (Q/K)**(1./ALFA) (K=sqrt(SLOPE)/MAN_N)
   CM = (Q2(JXB)-Q1(JXB))/(A2-A1)             ! NB:  A1,A2 are river stage
   ! update merged point
   T1(JXB) = T1(JXB) + XB/WC(JXB) - XB/CM     ! updated starting point
   WC(JXB) = CM
   ! if input elements are merged, then reduce index of merged element plus all remaining elements
   MF(IX(IXB):NI) = MF(IX(IXB):NI)-1         ! NI is the original size of the input
   ! re-number elements, ommitting the element just merged
   IX(IXB:NN) = IX(IXB+1:NN+1)               ! index (minimum index value of each merged particle)
   T1(IXB:NN) = T1(IXB+1:NN+1)               ! entry time
   WC(IXB:NN) = WC(IXB+1:NN+1)               ! wave celerity
   Q1(IXB:NN) = Q1(IXB+1:NN+1)               ! unmodified flows
   Q2(IXB:NN) = Q2(IXB+1:NN+1)               ! unmodified flows
   ! update X - already got the "closest shock to start", see if there are any other shocks
   X = XB
   ! --------------------------------------------------------------------------------------
  END DO GOTALL
 ENDIF GT_ONE

 ICOUNT=0
 ! ----------------------------------------------------------------------------------------
 ! perform the routing
 ! ----------------------------------------------------------------------------------------
 DO IROUTE = 1,NN    ! loop through the remaining particles (shocks,waves) (NM=NI-NN have been merged)
  ! check
  if(jRch==ixDesire) print*, 'wc(iRoute), nn = ', wc(iRoute), nn
  ! check that we have non-zero flow
  if(WC(IROUTE) < verySmall)then
   write(message,'(a,i0)') trim(message)//'zero flow for reach id ', NETOPO_in(jRch)%REACHID
   ierr=20; return
  endif
  ! compute the time the shock will exit the reach
  TEXIT = MIN(XMX/WC(IROUTE) + T1(IROUTE), HUGE(T1))
  ! compute the time the next shock will exit the reach
  IF (IROUTE.LT.NN) TNEXT = MIN(XMX/WC(IROUTE+1) + T1(IROUTE+1), HUGE(T1))
  IF (IROUTE.EQ.NN) TNEXT = HUGE(T1)
  ! check if element is merged
  MERGED: IF(Q1(IROUTE).NE.Q2(IROUTE)) THEN
   ! check if merged element has exited
   IF(TEXIT.LT.T_END) THEN
    ! when a merged element exits, save just the top and the bottom of the shock
    ! (identify the exit time for the "slower" particle)
    TEXIT2 = MIN(TEXIT+1.0D0, TEXIT + 0.5D0*(MIN(TNEXT,T_END)-TEXIT))
    ! unsure what will happen in the rare case if TEXIT and TEXIT2 are the same
    IF (TEXIT2.EQ.TEXIT) THEN
     ierr=30; message=trim(message)//'TEXIT equals TEXIT2 in kinwav'; return
    ENDIF
    ! fill output arrays
    CALL RUPDATE(Q1(IROUTE),T1(IROUTE),TEXIT,ierr,cmessage)    ! fill arrays w/ Q1, T1, + run checks
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
    CALL RUPDATE(Q2(IROUTE),T1(IROUTE),TEXIT2,ierr,cmessage)   ! fill arrays w/ Q2, T1, + run checks
    if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
   ELSE                                      ! merged elements have not exited
    ! when a merged element does not exit, need to disaggregate into original particles
    DO JROUTE=1,NI                           ! loop thru # original inputs
     IF(MF(JROUTE).EQ.IROUTE) &
      CALL RUPDATE(Q0(JROUTE),T0(JROUTE),TEXIT,ierr,cmessage)  ! fill arrays w/ Q0, T0, + run checks
      if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
    END DO  ! JROUTE
   ENDIF   ! TEXIT
  ! now process un-merged particles
  ELSE MERGED  ! (i.e., not merged)
   CALL RUPDATE(Q1(IROUTE),T1(IROUTE),TEXIT,ierr,cmessage)     ! fill arrays w/ Q1, T1, + run checks
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
  ENDIF MERGED
 END DO
 ! update arrays
 NQ2 = ICOUNT
 RETURN

 contains

  subroutine RUPDATE(QNEW,TOLD,TNEW,ierr,message)
    REAL(DP),INTENT(IN)                        :: QNEW      ! Q0,Q1, or Q2
    REAL(DP),INTENT(IN)                        :: TOLD,TNEW ! entry/exit times
    integer(i4b), intent(out)                  :: ierr      ! error code
    character(*), intent(out)                  :: message   ! error message
    ! initialize error control
    ierr=0; message='RUPDATE/'
    ! ---------------------------------------------------------------------------------------
    ! Used to compute the time each element will exit stream segment & update routing flag
    ! NB: internal subroutine so all data from host is available
    ! ---------------------------------------------------------------------------------------
    ICOUNT=ICOUNT+1
    ! check for array bounds exceeded
    IF (ICOUNT.GT.SIZE(Q_JRCH)) THEN
     ierr=60; message=trim(message)//'array bounds exceeded'; return
    ENDIF
    ! fill output arrays
    Q_JRCH(ICOUNT) = QNEW                         ! flow (Q1 always smaller than Q2)
    TENTRY(ICOUNT) = TOLD                         ! time - note, T1 altered if element merged
    T_EXIT(ICOUNT) = TNEW
    ! time check -- occurs when disaggregating merged elements
    IF (ICOUNT.GT.1) THEN
     IF (T_EXIT(ICOUNT).LE.T_EXIT(ICOUNT-1)) T_EXIT(ICOUNT)=T_EXIT(ICOUNT-1)+1.
    ENDIF
    ! another time check -- rare problem when the shock can get the same time as tstart
    IF(ICOUNT.EQ.1.AND.T_EXIT(ICOUNT).LE.T_START) T_EXIT(ICOUNT)=T_START+1.
    ! update flag for routed elements
    IF(T_EXIT(ICOUNT).LT.T_END) FROUTE(ICOUNT) =.TRUE.
  end subroutine RUPDATE

 end subroutine KINWAV_RCH

 ! *********************************************************************
 ! new subroutine: calculate time-step averages from irregular values
 ! *********************************************************************
 subroutine INTERP_RCH(TOLD,QOLD,TNEW,QNEW,IERR,MESSAGE)
 ! ----------------------------------------------------------------------------------------
 ! Creator(s):
 !   Unknown (original Tideda routine?), fairly old
 !   Martyn Clark, 2006: major clean-up and re-write
 !
 ! ----------------------------------------------------------------------------------------
 ! Purpose:
 !
 !   Used to calculate time step averages from a set of irregularly spaced values
 !    (provides one less output data value -- average BETWEEN time steps)
 !
 ! ----------------------------------------------------------------------------------------
 ! I/O:
 !
 !   Input(s):
 !   ---------
 !     TOLD: vector of times
 !     QOLD: vector of flows
 !     TNEW: vector of desired output times
 !
 !   Outputs:
 !   --------
 !     QNEW: vector of interpolated output [dimension = TNEW-1 (average BETWEEN intervals)]
 !     IERR: error code (1 = bad bounds)
 !
 ! ----------------------------------------------------------------------------------------
 ! Structures Used:
 !
 !   NONE
 !
 ! ----------------------------------------------------------------------------------------
 ! Method:
 !
 !   Loop through all output times (can be just 2, start and end of the time step)
 !
 !   For each pair of output times, integrate over the irregularly-spaced data
 !   values.
 !
 !   First, estimate the area under the curve at the start and end of the time step.
 !   Identify index values IBEG and IEND that span the start and end of the time
 !   step: TOLD(IBEG-1) < T0 <= TOLD(IBEG), and TOLD(IEND-1) < T1 <= TOLD(IEND).
 !   Use linear interpolation to estimate the value at T0 (QEST0) and T1 (QEST1).
 !   The area under the curve at the start/end of the time step is then simply
 !   (TOLD(IBEG) - T0) and (T1 - TOLD(IEND-1)), and the corresponding data values
 !   are 0.5*(QEST0 + QOLD(IBEG)) and 0.5*(QOLD(IEND-1) + QEST1).
 !
 !   Second, integrate over the remaining datapoints between T0 and T1.  The area
 !   for the middle points is (TOLD(i) - TOLD(i-1)), and the corresponding data
 !   values are (QOLD(i) - QOLD(i-1)).
 !
 !   Finally, divide the sum of the data values * area by the sum of the areas
 !   (which in this case is simply T1-T0).
 !
 !   A special case occurs when both the start and the end points of the time step
 !   lie between two of the irregularly-spaced input data values.  Here, use linear
 !   interpolation to estimate values at T0 and T1, and simply average the
 !   interpolated values.
 !
 !   NB: values of TOLD with times <= T0 and >= T1 are required for reliable
 !   estimates of time step averages.
 !
 ! ----------------------------------------------------------------------------------------
 ! Source:
 !
 !   This routine is base on the subroutine interp, in file kinwav_v7.f
 !
 ! ----------------------------------------------------------------------------------------
 ! Modifications to source (mclark@ucar.edu):
 !
 !   * All variables are now defined (IMPLICIT NONE) and described (comments)
 !
 !   * Added extra comments
 !
 !   * Replaced GOTO statements with DO loops and IF statements
 !
 ! ----------------------------------------------------------------------------------------
 ! Future revisions:
 !
 !   (none planned)
 !
 ! --------------------------------------------------------------------------------------------
 IMPLICIT NONE
 ! Input
 REAL(DP), DIMENSION(:), INTENT(IN)          :: TOLD     ! input time array
 REAL(DP), DIMENSION(:), INTENT(IN)          :: QOLD     ! input flow array
 REAL(DP), DIMENSION(:), INTENT(IN)          :: TNEW     ! desired output times
 ! Output
 REAL(DP), DIMENSION(:), INTENT(OUT)         :: QNEW     ! flow averaged for desired times
 INTEGER(I4B), INTENT(OUT)                   :: IERR     ! error, 1= bad bounds
 character(*), intent(out)                   :: MESSAGE  ! error message
 ! Internal
 INTEGER(I4B)                                :: NOLD     ! number of elements in input array
 INTEGER(I4B)                                :: NNEW     ! number of desired new times
 INTEGER(I4B)                                :: IOLDLOOP ! loop through input times
 INTEGER(I4B)                                :: INEWLOOP ! loop through desired times
 REAL(DP)                                    :: T0,T1    ! time at start/end of the time step
 INTEGER(I4B)                                :: IBEG     ! identify input times spanning T0
 INTEGER(I4B)                                :: IEND     ! identify input times spanning T1
 INTEGER(I4B)                                :: IMID     ! input times in middle of the curve
 REAL(DP)                                    :: AREAB    ! area at the start of the time step
 REAL(DP)                                    :: AREAE    ! area at the end of the time step
 REAL(DP)                                    :: AREAM    ! area at the middle of the time step
 REAL(DP)                                    :: AREAS    ! sum of all areas
 REAL(DP)                                    :: SLOPE    ! slope between two input data values
 REAL(DP)                                    :: QEST0    ! flow estimate at point T0
 REAL(DP)                                    :: QEST1    ! flow estimate at point T1
 ! --------------------------------------------------------------------------------------------
 IERR=0; message='INTERP_RCH/'

 ! get array size
 NOLD = SIZE(TOLD); NNEW = SIZE(TNEW)

 ! check that the input time series starts before the first required output time
 ! and ends after the last required output time
 IF( (TOLD(1).GT.TNEW(1)) .OR. (TOLD(NOLD).LT.TNEW(NNEW)) ) THEN
  IERR=1; message=trim(message)//'bad bounds'; RETURN
 ENDIF

 ! loop through the output times
 DO INEWLOOP=2,NNEW

  T0 = TNEW(INEWLOOP-1)                      ! start of the time step
  T1 = TNEW(INEWLOOP)                        ! end of the time step

  IBEG=1
  ! identify the index values that span the start of the time step
  BEG_ID: DO IOLDLOOP=2,NOLD
   IF(T0.LE.TOLD(IOLDLOOP)) THEN
    IBEG = IOLDLOOP
    EXIT
   ENDIF
  END DO BEG_ID

  IEND=1
  ! identify the index values that span the end of the time step
  END_ID: DO IOLDLOOP=1,NOLD
   IF(T1.LE.TOLD(IOLDLOOP)) THEN
    IEND = IOLDLOOP
    EXIT
   ENDIF
  END DO END_ID

  ! initialize the areas
  AREAB=0D0; AREAE=0D0; AREAM=0D0

  ! special case: both TNEW(INEWLOOP-1) and TNEW(INEWLOOP) are within two original values
  ! (implies IBEG=IEND) -- estimate values at both end-points and average
  IF(T1.LT.TOLD(IBEG)) THEN
   SLOPE = (QOLD(IBEG)-QOLD(IBEG-1))/(TOLD(IBEG)-TOLD(IBEG-1))
   QEST0 = SLOPE*(T0-TOLD(IBEG-1)) + QOLD(IBEG-1)
   QEST1 = SLOPE*(T1-TOLD(IBEG-1)) + QOLD(IBEG-1)
   QNEW(INEWLOOP-1) = 0.5*(QEST0 + QEST1)
   CYCLE ! loop back to the next desired time
  ENDIF

  ! estimate the area under the curve at the start of the time step
  IF(T0.LT.TOLD(IBEG)) THEN  ! if equal process as AREAM
   SLOPE = (QOLD(IBEG)-QOLD(IBEG-1))/(TOLD(IBEG)-TOLD(IBEG-1))
   QEST0 = SLOPE*(T0-TOLD(IBEG-1)) + QOLD(IBEG-1)
   AREAB = (TOLD(IBEG)-T0) * 0.5*(QEST0 + QOLD(IBEG))
  ENDIF

  ! estimate the area under the curve at the end of the time step
  IF(T1.LT.TOLD(IEND)) THEN  ! if equal process as AREAM
   SLOPE = (QOLD(IEND)-QOLD(IEND-1))/(TOLD(IEND)-TOLD(IEND-1))
   QEST1 = SLOPE*(T1-TOLD(IEND-1)) + QOLD(IEND-1)
   AREAE = (T1-TOLD(IEND-1)) * 0.5*(QOLD(IEND-1) + QEST1)
  ENDIF

  ! check if there are extra points to process
  IF(IBEG.LT.IEND) THEN
   ! loop through remaining points
   DO IMID=IBEG+1,IEND
    IF(IMID.LT.IEND .OR. &
      ! process the end slice as AREAM, but only if not already AREAB
      (IMID.EQ.IEND.AND.T1.EQ.TOLD(IEND).AND.T0.LT.TOLD(IEND-1)) ) THEN
       ! compute AREAM
       AREAM = AREAM + (TOLD(IMID) - TOLD(IMID-1)) * 0.5*(QOLD(IMID-1) + QOLD(IMID))
    ENDIF   ! if point is valid
   END DO  ! IMID
  ENDIF   ! If there is a possibility that middle points even exist

  ! compute time step average
  AREAS = AREAB + AREAE + AREAM            ! sum of all areas
  QNEW(INEWLOOP-1) = AREAS / (T1-T0)       ! T1-T0 is the sum of all time slices

 END DO

 end subroutine INTERP_RCH

end module kwt_route_module
