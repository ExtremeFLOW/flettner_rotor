
!> @file trip.f
!! @ingroup trip_line
!! @brief Tripping function for AMR version of nek5000
!! @note  This version uses developed framework parts. This is because
!!   I'm in a hurry and I want to save some time writing the code. So
!!   I reuse already tested code and focuse important parts. For the
!!   same reason for now only lines parallel to z axis are considered. 
!!   The tripping is based on a similar implementation in the SIMSON code
!!   (Chevalier et al. 2007, KTH Mechanics), and is described in detail 
!!   in the paper Schlatter & Örlü, JFM 2012, DOI 10.1017/jfm.2012.324.
!! @author Adam Peplinski
!! @date May 03, 2018

module trip
  use neko
  use device_inhom_dirichlet
  implicit none

! max number of lines and Fourier modes
  integer, parameter :: trip_nline_max=2
  integer, parameter :: trip_nmode_max=500
  real(kind=rp), parameter :: pi = 4.0_rp*atan(1.0_rp)
! max number of random phase sets stored; 1- time independent, 2, 3 and 4 - time dependent
! I keep two old random pahase sets to get correct restart after AMR refinement
  integer, parameter :: trip_nset_max = 4
  integer, parameter :: ldim = 3 !lets hardcode this for now gosh


  type, public :: trip_t 

     type(dofmap_t), pointer :: dof
     type(mesh_t), pointer :: msh
     type(space_t), pointer :: Xh
     integer :: id
   
     ! timer id
     integer :: tmr_id
   
   ! initialisation flag
     logical :: ifinit = .false.
   
   ! runtime parameter part
   ! section id
     integer :: sec_id    
   ! parameter section
     integer :: nline                  !< @var number of tripping lines
     integer :: nline_id
     real(kind=rp) :: tiamp                     !< @var time independent amplitude
     integer :: tiamp_id
     real(kind=rp) :: tdamp                     !< @var time dependent amplitude
     integer :: tdamp_id
     real(kind=rp) :: spos(3,trip_nline_max) !< @var coordinates of starting point of tripping line
     integer :: spos_id(3,trip_nline_max)
     real(kind=rp) :: epos(3,trip_nline_max) !< @var coordinates of ending point of tripping line
     integer :: epos_id(3,trip_nline_max)
     real(kind=rp) :: smth(3,trip_nline_max) !< @var smoothing radius
     integer :: smth_id(3,trip_nline_max)
     logical :: lext(trip_nline_max)    !< @var do we extend a line beyond starting and endig points
     integer :: lext_id(trip_nline_max)
     real(kind=rp) :: rota(trip_nline_max)      !< @var elipse rotation angle
     integer :: rota_id(trip_nline_max)
     integer :: nmode(trip_nline_max)  !< @var number of Fourier modes
     integer :: nmode_id(trip_nline_max)
     real(kind=rp) :: tdt(trip_nline_max)       !< @var time step for tripping
     integer :: tdt_id(trip_nline_max)
   
   ! inverse line length
     real(kind=rp) :: ilngt(trip_nline_max)
   
   ! inverse smoothing radius
     real(kind=rp) :: ismth(3,trip_nline_max)
     
   ! projection of 3D pionts on 1D line
     real(kind=rp), allocatable :: prj(:,:)
   
   ! number of points in 1D projection
     integer npoint(trip_nline_max)
     
   ! mapping of 3D array to 1D projection array
     integer, allocatable :: map(:,:,:,:,:)
   
   ! function for smoothing of the forcing
     real(kind=rp), allocatable :: fsmth(:,:,:,:,:)
   
   ! mask for tripping
     integer, allocatable :: mask(:)
     type(c_ptr) :: mask_d = C_NULL_PTR
     real(kind=rp), allocatable :: fsmth_mask(:)
     type(c_ptr) :: fsmth_mask_d = C_NULL_PTR
   ! forces for trippping
     type(c_ptr) :: ftripx_d = C_NULL_PTR
     type(c_ptr) :: ftripy_d = C_NULL_PTR
     type(c_ptr) :: ftripz_d = C_NULL_PTR
   ! force for interpolation
     type(c_ptr) :: f_interpolate_d(trip_nset_max)
   ! seed for random number generator; different for each line
     integer :: seed(trip_nline_max)
   
   ! number of tripping time intervals
     integer :: ntdt(trip_nline_max), ntdt_old(trip_nline_max)
     
   ! set of random phases (static, current and prevoious)
     real(kind=rp) :: rphs(trip_nmode_max,trip_nset_max,trip_nline_max)
   
   ! set of forcing arrays (static, current and prevoious)
     real(kind=rp), allocatable :: frcs(:,:,:)
   
   ! tripping array; interpolated value to set in 3D arrays
     real(kind=rp), allocatable :: ftrp(:,:)
    
     integer :: iff(trip_nline_max), iy(trip_nline_max)
     integer :: ir(97,trip_nline_max)
 contains
      procedure, pass(this) :: apply => trip_forcing
      procedure, pass(this) :: apply_device => trip_forcing_device
      procedure, pass(this) :: init => trip_init
      procedure, pass(this) :: update => trip_update
      procedure, pass(this) :: reset => trip_reset
      procedure, pass(this) :: ran2 => trip_ran2
   end type trip_t

!=======================================================================
!> @brief Register tripping module
!! @ingroup trip_line
!! @note This routine should be called in frame_usr_register
contains
!=======================================================================
!> @brief Initilise tripping module
!! @ingroup trip_line
!! @note This routine should be called in frame_usr_init
  subroutine trip_init(this, dof, nline, nmode, tiamp, tdamp, spos, epos, smth, lext, rota, tdt, time)
    class(trip_t) :: this
    integer, intent(in) :: nline, nmode(trip_nline_max)
    real(kind=rp), intent(inout), dimension(3,trip_nline_max) :: spos, epos, smth
    real(kind=rp), intent(inout) ::  rota(trip_nline_max), tdt(trip_nline_max)
    logical, intent(inout) :: lext(trip_nline_max)
    real(kind=rp), intent(in) :: time, tiamp, tdamp
    type(dofmap_t), target :: dof
    integer :: itmp
    real(kind=rp) :: rtmp
    logical :: ltmp

    integer :: il, jl

    this%dof => dof
    this%msh => dof%msh
    this%Xh => dof%Xh

    ! get runtime parameters
    this%nline = nline
    this%nmode = nmode
    this%tiamp = tiamp
    this%tdamp = tdamp
    this%spos = spos
    this%epos = epos
    this%smth = smth
    this%lext = lext
    this%rota = rota
    this%tdt = tdt
    allocate(this%prj(dof%size(),trip_nline_max))
    allocate(this%map(this%Xh%lz,dof%Xh%ly,dof%Xh%lz,dof%msh%nelv,trip_nline_max))
    allocate(this%fsmth(this%Xh%lz,this%Xh%ly,this%Xh%lz,dof%msh%nelv,trip_nline_max))
    allocate(this%frcs(dof%size(),trip_nset_max,trip_nline_max))
    allocate(this%ftrp(dof%size(),trip_nline_max))






!this%tdt =     do il=1,trip_nline
!       do jl=1,LDIM
!          call rprm_rp_get(itmp,rtmp,ltmp,ctmp,trip_spos_id(jl,il),
!   $           rpar_real)
!          call rprm_rp_get(itmp,rtmp,ltmp,ctmp,trip_epos_id(jl,il),
!   $           rpar_real)
!          trip_epos(jl,il) = rtmp
!          call rprm_rp_get(itmp,rtmp,ltmp,ctmp,trip_smth_id(jl,il),
!   $           rpar_real)
!          trip_smth(jl,il) = abs(rtmp)
!       enddo
!       call rprm_rp_get(itmp,rtmp,ltmp,ctmp,trip_lext_id(il),
!   $        rpar_log)
!       trip_lext(il) = ltmp
!       call rprm_rp_get(itmp,rtmp,ltmp,ctmp,trip_rota_id(il),
!   $        rpar_real)
!       trip_rota(il) = rtmp
!       call rprm_rp_get(itmp,rtmp,ltmp,ctmp,trip_nmode_id(il),
!   $        rpar_int)
!       trip_nmode(il) = itmp
!       call rprm_rp_get(itmp,rtmp,ltmp,ctmp,trip_tdt_id(il),
!   $        rpar_real)
!       trip_tdt(il) = rtmp
!    enddo

    ! get sure z position of stating point is lower than ending point position
    do il=1,this%nline
       if (this%spos(ldim,il).gt.this%epos(ldim,il)) then
          do jl=1,LDIM
             rtmp = this%spos(jl,il)
             this%spos(jl,il) = this%epos(jl,il)
             this%epos(jl,il) = rtmp
          enddo
       endif
    enddo

    ! get inverse line lengths and smoothing radius
    do il=1,this%nline
       this%ilngt(il) = 0.0
       do jl=1,LDIM
          this%ilngt(il) = this%ilngt(il) + (this%epos(jl,il)-&
                           this%spos(jl,il))**2
       enddo
       if (this%ilngt(il).gt.0.0) then
          this%ilngt(il) = 1.0/sqrt(this%ilngt(il))
       else
          this%ilngt(il) = 1.0
       endif
       do jl=1,LDIM
          if (this%smth(jl,il).gt.0.0) then
             this%ismth(jl,il) = 1.0/this%smth(jl,il)
          else
             this%ismth(jl,il) = 1.0
          endif
       enddo
    enddo

    ! get 1D projection and array mapping
    call trip_1dprj(this)

    ! initialise random generator seed and number of time intervals
    do il=1,this%nline
       this%seed(il) = -32*il
       this%ntdt(il) = 1 - trip_nset_max
       this%ntdt_old(il) = this%ntdt(il)
       this%iff(il) = 0.0
    enddo

    ! generate random phases (time independent and time dependent)
    call trip_rphs_get(this, time)
    if ((NEKO_BCKND_CUDA .eq. 1) .or. (NEKO_BCKND_HIP .eq. 1) &
       .or. (NEKO_BCKND_OPENCL .eq. 1)) then
       call trip_init_device(this)
    end if
    ! get forcing
    call trip_frcs_get(this, time, .true.)
    
    ! everything is initialised
    this%ifinit=.true.

  end subroutine
!=======================================================================
!> @brief Update tripping
!! @ingroup trip_line
  subroutine trip_update(this, time)
    class(trip_t), intent(inout) :: this
    ! local variables
    real(kind=rp) :: time

!-----------------------------------------------------------------------
    ! update random phases (time independent and time dependent)
    call trip_rphs_get(this,time)

    ! update forcing
    call trip_frcs_get(this,time,.false.)

  end subroutine trip_update 
!=======================================================================
!> @brief Compute tripping forcing
!! @ingroup trip_line
!! @param[inout] ffx,ffy,ffz     forcing; x,y,z component
!! @param[in]    ix,iy,iz        GLL point index
!! @param[in]    iel             local element number
  subroutine trip_forcing(this, ffx,ffy,ffz,ix,iy,iz,iel)
    class(trip_t), intent(inout) :: this
    real(kind=rp), intent(inout) :: ffx, ffy, ffz
    integer, intent(in) :: ix,iy,iz,iel
    integer :: ipos,il
    real(kind=rp) :: ffn

    do il= 1, this%nline
       ffn = this%fsmth(ix,iy,iz,iel,il)
       if (ffn.gt.0.0) then
          ipos = this%map(ix,iy,iz,iel,il)
          ffn = this%ftrp(ipos,il)*ffn

          ffx =ffx - ffn*sin(this%rota(il))
          ffy =ffy  +ffn*cos(this%rota(il))
       endif
    enddo
  end subroutine trip_forcing
!> @brief Compute tripping forcing
!! @ingroup trip_line
!! @param[inout] ffx,ffy,ffz     forcing; x,y,z component
!! @param[in]    ix,iy,iz        GLL point index
!! @param[in]    iel             local element number
  subroutine trip_forcing_device(this, fx_d,fy_d,fz_d)
    class(trip_t), intent(inout) :: this
    type(c_ptr), intent(inout) :: fx_d, fy_d, fz_d


    call device_rzero(fx_d,this%dof%size())
    call device_rzero(fy_d,this%dof%size())
    call device_rzero(fz_d,this%dof%size())
    
    if (this%mask(0) .gt. 0) &
       call device_inhom_dirichlet_apply_vector(this%mask_d,fx_d,fy_d,fz_d,&
            this%ftripx_d,this%ftripy_d,this%ftripz_d,this%mask(0))
    !do il= 1, this%nline
    !   ffn = this%fsmth(ix,iy,iz,iel,il)
    !   if (ffn.gt.0.0) then
    !      ipos = this%map(ix,iy,iz,iel,il)
    !      ffn = this%ftrp(ipos,il)*ffn

    !      ffx =ffx - ffn*sin(this%rota(il))
    !      ffy =ffy  +ffn*cos(this%rota(il))
    !   endif
    !enddo
  end subroutine trip_forcing_device
!=======================================================================
!> @brief Reset tripping
!! @ingroup trip_line
  subroutine trip_reset(this, time)
    ! local variables
    class(trip_t) :: this
    real(kind=rp) :: time
      
    ! get 1D projection and array mapping
    call trip_1dprj(this)
    
    ! update forcing
    call trip_frcs_get(this,time,.true.)

  end subroutine trip_reset
!=======================================================================
!> @brief Get 1D projection, array mapping and forcing smoothing
!! @ingroup trip_line
!! @details This routine is just a simple version supporting only lines
!!   paralles to z axis. In future it can be generalised.
!! @remark This routine uses global scratch space \a CTMP0 and \a CTMP1
  subroutine trip_1dprj(this)
    class(trip_t) :: this
    real(kind=rp), allocatable :: lcoord(:)
    integer, allocatable :: lmap(:)
    integer :: npxy, npel, nptot, itmp, jtmp, ktmp, eltmp, istart
    integer :: il, jl, nx1
    real(kind=rp) :: xl, yl, zl, xr, yr, rota, rtmp, ptmp
    real(kind=rp), parameter :: epsl = 1.0d-10

    npxy = this%Xh%lxy
    npel = this%Xh%lxyz
    nx1 = this%Xh%lx
    nptot = this%dof%size()
    allocate(lcoord(nptot), lmap(nptot))
    
    ! for each line
    do il=1,this%nline
       ! reset mapping array
       !call ifill(this%map(1,1,1,1,il),-1,nptot)
       do jl = 1, nptot
          this%map(jl,1,1,1,il) = -1
       end do
  
       ! Get coordinates and sort them
       call copy(lcoord,this%dof%z,nptot)
       call sort(lcoord,lmap,nptot)
       ! get smoothing profile
       rota = this%rota(il)
       ! initialize smoothing factor
       call rzero(this%fsmth(1,1,1,1,il),nptot)
       this%npoint(il) = 0
       if (.not.this%lext(il) .and.&
          (lcoord(nptot).lt. (this%spos(ldim,il)-3.0*this%smth(ldim,il)) .or. &
          (lcoord(1).gt.&
          (this%epos(ldim,il)+3.0*this%smth(ldim,il))))) then
          exit
       end if
  
       ! if we do not extend a line exclude points below line start (z coordinate matters only)
       ! this cannot be mixed with Gauss profile
       istart = 1
       if (.not.this%lext(il)) then
          do jl=1,nptot
             if (lcoord(jl).lt. &
                 (this%spos(ldim,il)-3.0_rp*this%smth(ldim,il))) then
                istart = istart+1
             else
                exit
             endif
          enddo
       endif

       
       ! find unique entrances and provide mapping
       this%npoint(il) = 1
       this%prj(this%npoint(il),il) = lcoord(istart)
       itmp = lmap(istart)-1
       eltmp = itmp/npel + 1
       itmp = itmp - npel*(eltmp-1)
       ktmp = itmp/npxy + 1
       itmp = itmp - npxy*(ktmp-1)
       jtmp = itmp/nx1 + 1
       itmp = itmp - nx1*(jtmp-1) + 1
       this%map(itmp,jtmp,ktmp,eltmp,il) = this%npoint(il)
       do jl=istart+1,nptot
          ! if line is not extended finish at proper position
          if (.not.this%lext(il).and.(lcoord(jl).gt. &
              (this%epos(ldim,il)+3.0_rp*this%smth(ldim,il)))) exit
  
          if((lcoord(jl)-this%prj(this%npoint(il),il)).gt. &
              max(epsl,abs(epsl*lcoord(jl)))) then
             this%npoint(il) = this%npoint(il) + 1
             this%prj(this%npoint(il),il) = lcoord(jl)
          endif
  
          itmp = lmap(jl)-1
          eltmp = itmp/npel + 1
          itmp = itmp - npel*(eltmp-1)
          ktmp = itmp/npxy + 1
          itmp = itmp - npxy*(ktmp-1)
          jtmp = itmp/nx1 + 1
          itmp = itmp - nx1*(jtmp-1) + 1
          this%map(itmp,jtmp,ktmp,eltmp,il) = this%npoint(il)
       enddo
           
       ! rescale 1D array
       do jl=1,this%npoint(il)
          this%prj(jl,il) = (this%prj(jl,il) - this%spos(ldim,il))&
              *this%ilngt(il)
       enddo
       
       ! get smoothing profile
       rota = this%rota(il)
       ! initialize smoothing factor
       call rzero(this%fsmth(1,1,1,1,il),nptot)
       
       do jl=1,nptot
          itmp = jl-1
          eltmp = itmp/npel + 1
          itmp = itmp - npel*(eltmp-1)
          ktmp = itmp/npxy + 1
          itmp = itmp - npxy*(ktmp-1)
          jtmp = itmp/nx1 + 1
          itmp = itmp - nx1*(jtmp-1) + 1
  
          ! take only mapped points
          istart = this%map(itmp,jtmp,ktmp,eltmp,il)
          if (istart.gt.0) then
  
             ! rotation
             xl = this%dof%x(itmp,jtmp,ktmp,eltmp)-this%spos(1,il)
             yl = this%dof%y(itmp,jtmp,ktmp,eltmp)-this%spos(2,il)
  
             xr = xl*cos(rota)+yl*sin(rota)
             yr = -xl*sin(rota)+yl*cos(rota)
  
             rtmp = (xr*this%ismth(1,il))**2+(yr*this%ismth(2,il))**2
             ! do we extend a line beyond its ends
             if (.not.this%lext(il)) then
                if (this%prj(istart,il).lt.0.0_rp) then
                    zl = this%dof%z(itmp,jtmp,ktmp,eltmp)-this%spos(ldim,il)
                   rtmp = rtmp+(zl*this%ismth(ldim,il))**2
                elseif(this%prj(istart,il).gt.1.0_rp) then
                    zl = this%dof%z(itmp,jtmp,ktmp,eltmp)-this%epos(ldim,il)
                   rtmp = rtmp+(zl*this%ismth(ldim,il))**2
                endif
             endif
             ! Gauss; cannot be used with lines not extended beyond their ending points
             !trip_fsmth(itmp,jtmp,ktmp,eltmp,il) = exp(-4.0*rtmp)
             ! limited support
             if (rtmp.lt.1.0_rp) then
                this%fsmth(itmp,jtmp,ktmp,eltmp,il) = &
                    exp(-rtmp)*(1.0_rp-rtmp)**2.0_rp
             else
                this%fsmth(itmp,jtmp,ktmp,eltmp,il) = 0.0_rp
             endif
          endif
  
       enddo
    enddo
    deallocate(lcoord, lmap)
  end subroutine      
  !=======================================================================
  !> @brief Generate set of random phases
  !! @ingroup trip_line
  subroutine trip_rphs_get(this, time)
    class(trip_t), intent(inout) :: this
    real(kind=rp), intent(in) :: time
    integer :: il, jl, kl
    integer :: itmp
  
!#ifdef DEBUG
!    character*3 str1, str2
!    integer iunit, ierr
!    ! call number
!    integer icalldl
!    save icalldl
!    data icalldl /0/
!#endif
    ! time independent part
    if (this%tiamp.gt.0.0.and..not.this%ifinit) then
       do il = 1, this%nline
          do jl=1, this%nmode(il)
             this%rphs(jl,1,il) = 2.0*pi*this%ran2(il)
          enddo
       enddo
    endif
  
    ! time dependent part
    do il = 1, this%nline
       itmp = int(time/this%tdt(il))
       !call bcast(itmp,ISIZE) ! just for safety
       do kl= this%ntdt(il)+1, itmp
          do jl= trip_nset_max,3,-1
             call copy(this%rphs(1,jl,il),this%rphs(1,jl-1,il), &
                  this%nmode(il))
          enddo
          do jl=1, this%nmode(il)
          this%rphs(jl,2,il) = 2.0_rp*pi*this%ran2(il)
          enddo
       enddo
       ! update time interval
       this%ntdt_old(il) = this%ntdt(il)
       this%ntdt(il) = itmp
    enddo

!#ifdef DEBUG
!    ! for testing
!    ! to output refinement
!    icalldl = icalldl+1
!    call io_file_freeid(iunit, ierr)
!    write(str1,'(i3.3)') NID
!    write(str2,'(i3.3)') icalldl
!    open(unit=iunit,file='trp_rps.txt'//str1//'i'//str2)
!  
!    do il=1,trip_nmode(1)
!       write(iunit,*) il,trip_rphs(il,1:4,1)
!    enddo
!  
!    close(iunit)
!#endif

  end subroutine
!=======================================================================
!> @brief A simple portable random number generator
!! @ingroup trip_line
!! @details  Requires 32-bit integer arithmetic. Taken from Numerical
!!   Recipes, William Press et al. Gives correlation free random
!!   numbers but does not have a very large dynamic range, i.e only
!!   generates 714025 different numbers. Set seed negative for
!!   initialization
!! @param[in]   il      line number
!! @return      ran
real(kind=rp) function trip_ran2(this,il)
    class(trip_t) :: this
    integer, intent(in) :: il
    ! local variables
    integer, parameter :: m=714025
    integer, parameter :: ia=1366
    integer, parameter :: ic=150889
    real, parameter :: rm=1./m
    integer :: j
    associate( seed => this%seed, iff => this%iff, iy => this%iy, ir => this%ir) 
    ! initialise
    if (seed(il).lt.0.or.iff(il).eq.0) then
       iff(il)=1
       seed(il)=mod(ic-seed(il),m)
       do j=1,97
          seed(il)=mod(ia*seed(il)+ic,m)
          ir(j,il)=seed(il)
       end do
       seed(il)=mod(ia*seed(il)+ic,m)
       iy(il)=seed(il)
    end if
    
    ! generate random number
    j=1+(97*iy(il))/m
    iy(il)=ir(j,il)
    trip_ran2=iy(il)*rm
    seed(il)=mod(ia*seed(il)+ic,m)
    ir(j,il)=seed(il)
    end associate

  end function
!=======================================================================
!> @brief Generate forcing along 1D line
!! @ingroup trip_line
!! @param[in] ifreset    reset flag
  subroutine trip_frcs_get(this, time, ifreset)
    ! argument list
    class(trip_t), intent(inout) :: this
    logical, intent(in) ::  ifreset
    real(kind=rp), intent(in) :: time
    integer :: il, jl, kl, ll
    integer :: istart, m
    real(kind=rp) :: theta0, theta
    logical :: ifntdt_dif
!#ifdef TRIP_PR_RST
!    ! variables necessary to reset pressure projection for P_n-P_n-2
!    integer nprv(2)
!    common /orthbi/ nprv
!
!    ! variables necessary to reset velocity projection for P_n-P_n-2
!    include 'VPROJ'
!#endif      
    ! local variables

!#ifdef DEBUG
!    character*3 str1, str2
!    integer iunit, ierr
!    ! call number
!    integer icalldl
!    save icalldl
!    data icalldl /0/
!#endif
    ! reset all
    if (ifreset) then
       if (this%tiamp.gt.0.0) then
          istart = 1
       else
          istart = 2
       endif
       do il= 1, this%nline
          do jl = istart, trip_nset_max
             call rzero(this%frcs(1,jl,il),this%npoint(il))
             do kl= 1, this%npoint(il)
                theta0 = 2*pi*this%prj(kl,il)
                do ll= 1, this%nmode(il)
                   theta = theta0*ll
                   this%frcs(kl,jl,il) = this%frcs(kl,jl,il) + &
                       sin(theta+this%rphs(ll,jl,il))
                enddo
             enddo
          enddo
       enddo
       ! rescale time independent part
       if (this%tiamp.gt.0.0) then
          do il= 1, this%nline
             call cmult(this%frcs(1,1,il),this%tiamp,this%npoint(il))
          enddo
       endif
       if ((NEKO_BCKND_CUDA .eq. 1) .or. (NEKO_BCKND_HIP .eq. 1) &
       .or. (NEKO_BCKND_OPENCL .eq. 1)) then
          call trip_update_forces_device(this)
       end if

    else
       ! reset only time dependent part if needed
       ifntdt_dif = .FALSE.
       do il= 1, this%nline
          if (this%ntdt(il).ne.this%ntdt_old(il)) then
             ifntdt_dif = .TRUE.
             do jl= trip_nset_max,3,-1
                call copy(this%frcs(1,jl,il),this%frcs(1,jl-1,il), &
                    this%npoint(il))
             enddo
             call rzero(this%frcs(1,2,il),this%npoint(il))
             do jl= 1, this%npoint(il)
                theta0 = 2*pi*this%prj(jl,il)
                do kl= 1, this%nmode(il)
                   theta = theta0*kl
                   this%frcs(jl,2,il) = this%frcs(jl,2,il) + &
                       sin(theta+this%rphs(kl,2,il))
                enddo
             enddo
             if ((NEKO_BCKND_CUDA .eq. 1) .or. (NEKO_BCKND_HIP .eq. 1) &
             .or. (NEKO_BCKND_OPENCL .eq. 1)) then
                call trip_update_forces_device(this)
             end if

          endif
       enddo
!         if (ifntdt_dif) then
!#ifdef TRIP_PR_RST
!            ! reset projection space
!            ! pressure
!            if (int(PARAM(95)).gt.0) then
!               PARAM(95) = ISTEP
!               nprv(1) = 0      ! veloctiy field only
!            endif
!            ! velocity
!            if (int(PARAM(94)).gt.0) then
!               PARAM(94) = ISTEP!+2
!               ivproj(2,1) = 0
!               ivproj(2,2) = 0
!               if (IF3D) ivproj(2,3) = 0
!            endif
!#endif
!         endif
    endif
      
    if ((NEKO_BCKND_CUDA .eq. 1) .or. (NEKO_BCKND_HIP .eq. 1) &
    .or. (NEKO_BCKND_OPENCL .eq. 1)) then
       ! get tripping for current time stepa
       m = this%mask(0)
       if ( m.gt. 0) then
          if (this%tiamp.gt.0.0) then
               call device_copy(this%ftripx_d,this%f_interpolate_d(1),m)
          else
               call device_rzero(this%ftripx_d,m)
          endif
          !> We only support one line for now!
          il = 1
          ! interpolation in time
          theta0= time/this%tdt(il)-real(this%ntdt(il))
          if (theta0.gt.0.0) then
             theta0=theta0*theta0*(3.0-2.0*theta0)
             theta = (1.0-theta0)*this%tdamp
             call device_add2s2(this%ftripx_d,this%f_interpolate_d(3),theta,m)
             theta = theta0*this%tdamp
             call device_add2s2(this%ftripx_d,this%f_interpolate_d(2),theta,m)
          else
             theta0=theta0+1.0
             theta0=theta0*theta0*(3.0-2.0*theta0)
             theta = (1.0-theta0)*this%tdamp
             call device_add2s2(this%ftripx_d,this%f_interpolate_d(4),theta,m)
             theta = theta0*this%tdamp
             call device_add2s2(this%ftripx_d,this%f_interpolate_d(3),theta,m)
          endif
          call device_col2(this%ftripx_d,this%fsmth_mask_d,m)
          call device_cmult2(this%ftripy_d,this%ftripx_d,cos(this%rota(1)),m)
          call device_cmult(this%ftripx_d,-sin(this%rota(1)),m)
          call device_rzero(this%ftripz_d,m)
       end if
     else
       ! get tripping for current time step
       if (this%tiamp.gt.0.0) then
          do il= 1, this%nline
            call copy(this%ftrp(1,il),this%frcs(1,1,il),this%npoint(il))
          enddo
       else
          do il= 1, this%nline
             call rzero(this%ftrp(1,il),this%npoint(il))
          enddo
       endif
       ! interpolation in time
       do il = 1, this%nline
          theta0= time/this%tdt(il)-real(this%ntdt(il))
          if (theta0.gt.0.0) then
             theta0=theta0*theta0*(3.0-2.0*theta0)
             !theta0=theta0*theta0*theta0*(10.0+(6.0*theta0-15.0)*theta0)
             do jl= 1, this%npoint(il)
                this%ftrp(jl,il) = this%ftrp(jl,il) + &
                    this%tdamp*((1.0-theta0)*this%frcs(jl,3,il) + &
                    theta0*this%frcs(jl,2,il))
             enddo
          else
             theta0=theta0+1.0
             theta0=theta0*theta0*(3.0-2.0*theta0)
             !theta0=theta0*theta0*theta0*(10.0+(6.0*theta0-15.0)*theta0)
             do jl= 1, this%npoint(il)
                this%ftrp(jl,il) = this%ftrp(jl,il) + &
                     this%tdamp*((1.0-theta0)*this%frcs(jl,4,il) + &
                     theta0*this%frcs(jl,3,il))
             enddo
          endif
       enddo
    end if

!#efdef DEBUG
!      ! for testing
!      ! to output refinement
!      icalldl = icalldl+1
!      call io_file_freeid(iunit, ierr)
!      write(str1,'(i3.3)') NID
!      write(str2,'(i3.3)') icalldl
!      open(unit=iunit,file='trp_fcr.txt'//str1//'i'//str2)
!
!      do il=1,trip_npoint(1)
!         write(iunit,*) il,trip_prj(il,1),trip_ftrp(il,1),
!     $        trip_frcs(il,1:4,1)
!      enddo
!
!      close(iunit)
!#endif
  end subroutine
  subroutine trip_init_device(this)
    type(trip_t) :: this
    integer, allocatable :: mask_temp(:)
    real(kind=rp), allocatable :: fsmth_mask_temp(:)
    integer :: i, j,n, m = 0
    integer(c_size_t) :: array_size
    n = this%dof%size()
    allocate(mask_temp(n), fsmth_mask_temp(n))
    
    do i = 1, n
       if (this%fsmth(i,1,1,1,1) .gt. 0.0) then
          m = m + 1
          mask_temp(m) = i
          fsmth_mask_temp(m) = this%fsmth(i,1,1,1,1)
       end if
    end do

    allocate(this%mask(0:m))
    allocate(this%fsmth_mask(m))
    this%mask(0) = m
    do i = 1, m
       this%mask(i) = mask_temp(i)
       this%fsmth_mask(i) = fsmth_mask_temp(i)
    end do

    deallocate(mask_temp, fsmth_mask_temp)
    call device_map(this%mask, this%mask_d, m+1)
    call device_map(this%fsmth_mask, this%fsmth_mask_d, m)
    call device_memcpy(this%mask, this%mask_d, m+1,HOST_TO_DEVICE)
    call device_memcpy(this%fsmth_mask, this%fsmth_mask_d, m,HOST_TO_DEVICE)
    array_size = rp*m
    do i = 1, trip_nset_max
       call device_alloc(this%f_interpolate_d(i),array_size)
       if (m .gt. 0) call device_rzero(this%f_interpolate_d(i),m)
    end do
    call device_alloc(this%ftripx_d,array_size)
    call device_alloc(this%ftripy_d,array_size)
    call device_alloc(this%ftripz_d,array_size)

  end subroutine trip_init_device


  subroutine trip_update_forces_device(this)
    type(trip_t) :: this
    real(kind=rp), allocatable :: frc_mask_temp(:,:)
    integer :: m, ipos, il, i, j
    m = this%mask(0)
    il = 1
    allocate(frc_mask_temp(m,trip_nset_max))
    call rzero(frc_mask_temp,m*trip_nset_max)
    do i = 1, m
       ipos = this%map(this%mask(i),1,1,1,1) 
       do j = 1, trip_nset_max
          frc_mask_temp(i, j) = this%frcs(ipos,j,il)
       end do
    end do
    do j = 1, trip_nset_max
       call device_memcpy_r1(frc_mask_temp(:,j),this%f_interpolate_d(j),m,HOST_TO_DEVICE)
    end do

  end subroutine trip_update_forces_device

!      subroutine trip_register()
!
!      ! local variables
!      integer lpmid, il
!      real(kind=rp) :: ltim
!      character*2 str
!
!      ! functions
!      real(kind=rp) :: dnekclock
!!-----------------------------------------------------------------------
!      ! timing
!      ltim = dnekclock()
!
!      ! check if the current module was already registered
!      call mntr_mod_is_name_reg(lpmid,trip_name)
!      if (lpmid.gt.0) then
!         call mntr_warn(lpmid,
!     $        'module ['//trim(trip_name)//'] already registered')
!         return
!      endif
!
!      ! find parent module
!      call mntr_mod_is_name_reg(lpmid,'FRAME')
!      if (lpmid.le.0) then
!         lpmid = 1
!         call mntr_abort(lpmid,
!     $        'parent module ['//'FRAME'//'] not registered')
!      endif
!
!      ! register module
!      call mntr_mod_reg(trip_id,lpmid,trip_name,
!     $      'Tripping along the line')
!
!      ! register timer
!      call mntr_tmr_is_name_reg(lpmid,'FRM_TOT')
!      call mntr_tmr_reg(trip_tmr_id,lpmid,trip_id,
!     $     'TRIP_TOT','Tripping total time',.false.)
!
!      ! register and set active section
!      call rprm_sec_reg(trip_sec_id,trip_id,'_'//adjustl(trip_name),
!     $     'Runtime paramere section for tripping module')
!      call rprm_sec_set_act(.true.,trip_sec_id)
!
!      ! register parameters
!      call rprm_rp_reg(trip_nline_id,trip_sec_id,'NLINE',
!     $     'Number of tripping lines',rpar_int,0,0.0,.false.,' ')
!
!      call rprm_rp_reg(trip_tiamp_id,trip_sec_id,'TIAMP',
!     $     'Time independent amplitude',rpar_real,0,0.0,.false.,' ')
!
!      call rprm_rp_reg(trip_tdamp_id,trip_sec_id,'TDAMP',
!     $     'Time dependent amplitude',rpar_real,0,0.0,.false.,' ')
!
!      do il=1, trip_nline_max
!         write(str,'(I2.2)') il
!
!         call rprm_rp_reg(trip_spos_id(1,il),trip_sec_id,'SPOSX'//str,
!     $     'Starting point X',rpar_real,0,0.0,.false.,' ')
!         
!         call rprm_rp_reg(trip_spos_id(2,il),trip_sec_id,'SPOSY'//str,
!     $     'Starting point Y',rpar_real,0,0.0,.false.,' ')
!
!         if (IF3D) then
!            call rprm_rp_reg(trip_spos_id(ldim,il),trip_sec_id,
!     $           'SPOSZ'//str,'Starting point Z',
!     $           rpar_real,0,0.0,.false.,' ')
!         endif
!        
!         call rprm_rp_reg(trip_epos_id(1,il),trip_sec_id,'EPOSX'//str,
!     $     'Ending point X',rpar_real,0,0.0,.false.,' ')
!         
!         call rprm_rp_reg(trip_epos_id(2,il),trip_sec_id,'EPOSY'//str,
!     $     'Ending point Y',rpar_real,0,0.0,.false.,' ')
!
!         if (IF3D) then
!            call rprm_rp_reg(trip_epos_id(ldim,il),trip_sec_id,
!     $           'EPOSZ'//str,'Ending point Z',
!     $           rpar_real,0,0.0,.false.,' ')
!         endif
!
!         call rprm_rp_reg(trip_smth_id(1,il),trip_sec_id,'SMTHX'//str,
!     $     'Smoothing length X',rpar_real,0,0.0,.false.,' ')
!         
!         call rprm_rp_reg(trip_smth_id(2,il),trip_sec_id,'SMTHY'//str,
!     $     'Smoothing length Y',rpar_real,0,0.0,.false.,' ')
!
!         if (IF3D) then
!            call rprm_rp_reg(trip_smth_id(ldim,il),trip_sec_id,
!     $           'SMTHZ'//str,'Smoothing length Z',
!     $           rpar_real,0,0.0,.false.,' ')
!         endif
!
!         call rprm_rp_reg(trip_lext_id(il),trip_sec_id,'LEXT'//str,
!     $        'Line extension',rpar_log,0,0.0,.false.,' ')
!      
!         call rprm_rp_reg(trip_rota_id(il),trip_sec_id,'ROTA'//str,
!     $        'Rotation angle',rpar_real,0,0.0,.false.,' ')
!         call rprm_rp_reg(trip_nmode_id(il),trip_sec_id,'NMODE'//str,
!     $     'Number of Fourier modes',rpar_int,0,0.0,.false.,' ')
!         call rprm_rp_reg(trip_tdt_id(il),trip_sec_id,'TDT'//str,
!     $     'Time step for tripping',rpar_real,0,0.0,.false.,' ')
!      enddo
!
!      ! set initialisation flag
!      trip_ifinit=.false.
!      
!      ! timing
!      ltim = dnekclock() - ltim
!      call mntr_tmr_add(trip_tmr_id,1,ltim)
!
!      return
!      end subroutine

end module trip

module user
  use neko
  use trip
  implicit none
  ! Case parameters
  real(kind=rp), parameter :: h = 1.0
  real(kind=rp), parameter :: gam = 20.0
  real(kind=rp), parameter :: rad = h/gam
  real(kind=rp), parameter :: n = 7
  real(kind=rp), parameter :: pw = 1/n
  real(kind=rp), parameter :: ucl = 1
  real(kind=rp), parameter :: alpha = 3
  real(kind=rp), parameter :: u_th2 = ucl*alpha
  real(kind=rp), parameter :: u_rho = 0.0
  real(kind=rp), parameter :: u_axial = 0.0
  real(kind=rp), parameter :: y0 = 0.0
  real(kind=rp), parameter :: y1 = 0.0
  real(kind=rp), parameter :: delta = 0.005*h
  type(trip_t) :: tripper
  real(kind=rp), allocatable :: sij(:,:,:,:,:)
  real(kind=rp) :: visc
  
  !Things for tripping
  real(kind=rp), parameter :: TIAMP   = 0.00_rp         
  real(kind=rp), parameter :: TDAMP   = 0.3_rp         
  real(kind=rp), parameter :: SPOSX01 = -4.5_rp         
  real(kind=rp), parameter :: SPOSY01 = 0.0_rp         
  real(kind=rp), parameter :: SPOSZ01 = -1.0_rp         
  real(kind=rp), parameter :: EPOSX01 = -4.5_rp         
  real(kind=rp), parameter :: EPOSY01 = 0.0_rp         
  real(kind=rp), parameter :: EPOSZ01 = 1.0_rp         
  real(kind=rp), parameter :: SMTHX01 = 1.36_rp         
  real(kind=rp), parameter :: SMTHY01 = 0.68_rp          ! 0.34
  real(kind=rp), parameter :: SMTHZ01 = 0.3_rp         
  real(kind=rp), parameter :: ROTA01  = 0.0_rp         
  integer, parameter :: NMODE01 = 40
  real(kind=rp), parameter :: TDT01   = 0.14_rp
  integer, parameter :: nline = 1
  logical, parameter :: LEXT01 = .false.
contains
  
  
  ! Register user defined functions (see user_intf.f90)
  subroutine user_setup(u)
    type(user_t), intent(inout) :: u
    u%fluid_usr_ic => user_ic
    u%fluid_usr_if => user_inflow_eval
    u%fluid_usr_f_vector => tripline
    u%fluid_usr_f => tripline_org
    u%user_init_modules => init_tripper
    u%usr_chk => user_do_stuff
    u%usr_msh_setup => cylinder_deform
  end subroutine user_setup

  subroutine init_tripper(t, u, v, w, p, c_Xh, params)
    real(kind=rp) :: t
    type(field_t), intent(inout) :: u
    type(field_t), intent(inout) :: v
    type(field_t), intent(inout) :: w
    type(field_t), intent(inout) :: p
    type(coef_t), intent(inout) :: c_Xh
    type(param_t), intent(inout) :: params
    integer :: nmode(trip_nline_max)
    real(kind=rp), dimension(3,trip_nline_max) :: spos, epos, smth
    real(kind=rp) :: rota(trip_nline_max), tdt(trip_nline_max)
    logical :: lext(trip_nline_max)
    integer :: lx

    spos(1,1) = SPOSX01    
    spos(2,1) = SPOSY01   
    spos(3,1) = SPOSZ01    
    epos(1,1)= EPOSX01    
    epos(2,1)= EPOSY01   
    epos(3,1)= EPOSZ01   
    smth(1,1)= SMTHX01    
    smth(2,1)= SMTHY01    
    smth(3,1)= SMTHZ01   
    rota(1) = ROTA01    
    nmode(1) = NMODE01 
    tdt(1) = TDT01   
    lext(1) = LEXT01

    call tripper%init( u%dof, nline, nmode, tiamp, tdamp, &
                       spos, epos, smth, lext, rota, tdt, t)
    lx = c_Xh%Xh%lx
    allocate(sij(lx, lx, lx, 6, c_Xh%msh%nelv))
    visc = 1.0/params%Re

  end subroutine init_tripper


  !> Tripline forcing
  subroutine tripline_org(u, v, w, j, k, l, e)
    real(kind=rp), intent(inout) :: u
    real(kind=rp), intent(inout) :: v
    real(kind=rp), intent(inout) :: w
    integer, intent(in) :: j
    integer, intent(in) :: k
    integer, intent(in) :: l
    integer, intent(in) :: e

    u = 0.0
    v = 0.0
    w = 0.0
   
    call tripper%apply(u,v,w,j,k,l,e) 

  end subroutine tripline_org

  subroutine tripline(f)
    class(source_t) :: f
    integer :: i, j, k, e
    real(kind=rp) :: u, v, w
    if ((NEKO_BCKND_CUDA .eq. 1) .or. (NEKO_BCKND_HIP .eq. 1) &
       .or. (NEKO_BCKND_OPENCL .eq. 1)) then
       call device_rzero(f%u_d,tripper%dof%size())
       call device_rzero(f%v_d,tripper%dof%size())
       call device_rzero(f%w_d,tripper%dof%size())
       call tripper%apply_device(f%u_d, f%v_d, f%w_d)
    else 
       do e = 1, tripper%msh%nelv
          do k = 1, tripper%Xh%lz
             do j = 1, tripper%Xh%ly
                do i = 1, tripper%Xh%lx
                   call tripline_org(u,v,w,i,j,k,e) 
                   f%u(i,j,k,e) = u
                   f%v(i,j,k,e) = v
                   f%w(i,j,k,e) = w
                end do
             end do
          end do
       end do
    end if
   end subroutine tripline

  subroutine cylinder_deform(msh)
    type(mesh_t), intent(inout) :: msh
    msh%apply_deform => cylinder_gen_curve
  end subroutine cylinder_deform
  
  subroutine cylinder_gen_curve(msh, x, y, z, lx, ly, lz)
    class(mesh_t) :: msh
    integer, intent(in) :: lx, ly, lz
    real(kind=rp), intent(inout) :: x(lx, lx, lx, msh%nelv)
    real(kind=rp), intent(inout) :: y(lx, lx, lx, msh%nelv)
    real(kind=rp), intent(inout) :: z(lx, lx, lx, msh%nelv)
    type(tuple_i4_t) :: el_and_facet
    real(kind=rp) :: th
    integer :: e, i, j ,k, l,  facet

    !The cylinders zone number is 7
    do l = 1,msh%labeled_zones(7)%size
       el_and_facet = msh%labeled_zones(7)%facet_el(l)
       facet = el_and_facet%x(1)
       e = el_and_facet%x(2)
       do k = 1, lz
          do j = 1, ly
              do i = 1, lx
                 if (index_is_on_facet(i,j,k,lx,ly,lz, facet)) then
                    th = atan2(z(i,j,k,e), x(i,j,k,e))
                    x(i,j,k,e) = rad * cos(th)
                    z(i,j,k,e) = rad * sin(th) 
                 end if
              end do
          end do
       end do
    end do
  end subroutine cylinder_gen_curve

  
  subroutine user_inflow_eval(u, v, w, x, y, z, nx, ny, nz, ix, iy, iz, ie)
    real(kind=rp), intent(inout) :: u
    real(kind=rp), intent(inout) :: v
    real(kind=rp), intent(inout) :: w
    real(kind=rp), intent(in) :: x
    real(kind=rp), intent(in) :: y
    real(kind=rp), intent(in) :: z
    real(kind=rp), intent(in) :: nx
    real(kind=rp), intent(in) :: ny
    real(kind=rp), intent(in) :: nz
    integer, intent(in) :: ix
    integer, intent(in) :: iy
    integer, intent(in) :: iz
    integer, intent(in) :: ie
    real(kind=rp) ::  u_th,dist,th, yy
    real(kind=rp) ::  arg

!   Two different regions (inflow & cyl) have the label 'v  '
!   Let compute the distance from the (0,0) in the x-y plane
!   to identify the proper one
    dist = sqrt(x**2 + z**2)

! --- INFLOW
    if (dist .gt. 1.1*rad) then
       u =  ucl*y**pw
    end if
! --- 

    w = 0.0
    v = 0.0
! --- SPINNING CYLINDER

    if (dist.lt.1.5*rad .and. y.gt. 0.1) then                      
       th = atan2(z,x)
       u = cos(th)*u_rho - sin(th)*u_th2
       w = sin(th)*u_rho + cos(th)*u_th2   
    end if     
                    
! --- 


!     Smoothing function for the velocity u_th on the spinning cylinder
!     to avoid gap in the at the bottom wall

!     u_th is smoothed if z0 < z < delta
!     u_th=1 if z >= delta
 

    yy = y + abs(y0) ! coordinate shift 

    if (dist .lt. 1.5*rad) then 
       if (yy.lt.delta) then
          arg  = yy/delta
          u_th = u_th2/(1.0_rp+exp(1.0_rp/(arg-1.0_rp)+1.0_rp/arg))
       else
          u_th = u_th2
       endif

       th = atan2(z,x)

       u = cos(th)*u_rho - sin(th)*u_th
       w = sin(th)*u_rho + cos(th)*u_th  
    end if
  end subroutine user_inflow_eval

  ! User defined initial condition
  subroutine user_ic(u, v, w, p, params)
    type(field_t), intent(inout) :: u
    type(field_t), intent(inout) :: v
    type(field_t), intent(inout) :: w
    type(field_t), intent(inout) :: p
    type(param_t), intent(inout) :: params
    integer :: i
    real(kind=rp) :: y

    do i = 1, u%dof%size()
       y = u%dof%y(i,1,1,1)
       u%x(i,1,1,1) =  ucl*y**pw
       v%x(i,1,1,1) = 0.0
       w%x(i,1,1,1) = 0.0
    end do
  end subroutine user_ic

  subroutine user_do_stuff(t, dt, tstep, u, v, w, p, coef)
    real(kind=rp), intent(in) :: t, dt
    integer, intent(in) :: tstep
    type(coef_t), intent(inout) :: coef
    type(field_t), intent(inout) :: u
    type(field_t), intent(inout) :: v
    type(field_t), intent(inout) :: w
    type(field_t), intent(inout) :: p

    call tripper%update(t)
    call calc_torque(tstep, coef%msh%labeled_zones(7), u, v, w, p, coef)

  end subroutine user_do_stuff
  
  subroutine calc_torque(tstep, zone, u, v, w, p, coef)
    integer, intent(in) :: tstep
    type(zone_t) :: zone
    type(field_t), intent(inout) :: u
    type(field_t), intent(inout) :: v
    type(field_t), intent(inout) :: w
    type(field_t), intent(inout) :: p
    type(coef_t), intent(inout) :: coef
    real(kind=rp) :: dgtq(3,4)
    real(kind=rp) :: dragpx = 0.0_rp ! pressure 
    real(kind=rp) :: dragpy = 0.0_rp
    real(kind=rp) :: dragpz = 0.0_rp
    real(kind=rp) :: dragvx = 0.0_rp ! viscous
    real(kind=rp) :: dragvy = 0.0_rp
    real(kind=rp) :: dragvz = 0.0_rp
    real(kind=rp) :: torqpx = 0.0_rp ! pressure 
    real(kind=rp) :: torqpy = 0.0_rp
    real(kind=rp) :: torqpz = 0.0_rp
    real(kind=rp) :: torqvx = 0.0_rp ! viscous
    real(kind=rp) :: torqvy = 0.0_rp
    real(kind=rp) :: torqvz = 0.0_rp
    real(kind=rp) :: dragx, dragy, dragz
    real(kind=rp) :: torqx, torqy, torqz
    integer :: ie, ifc, mem, nij, ierr
    dragx = 0.0
    dragy = 0.0
    dragz = 0.0


     !call add2s2(pm1,xm1,dpdx_mean,n)  ! Doesn't work if object is cut by 
     !call add2s2(pm1,ym1,dpdy_mean,n)  ! periodicboundary.  In this case,
     !call add2s2(pm1,zm1,dpdz_mean,n)  ! set ._mean=0 and compensate in
!
!    Compute sij
!
      nij = 6
      call comp_sij(sij,nij,u%x,v%x,w%x,coef%Xh,coef)
!
!
!     Fill up viscous array w/ default
!
      dragpx = 0.0
      dragpy = 0.0
      dragpz = 0.0
      dragvx = 0.0
      dragvy = 0.0
      dragvz = 0.0
      do mem  = 1,zone%size
         ie   = zone%facet_el(mem)%x(2)
         ifc   = zone%facet_el(mem)%x(1)
         call drgtrq(dgtq,coef%dof%x,coef%dof%y,coef%dof%z,sij,p%x,visc,ifc,ie, coef, coef%Xh)

         dragpx = dragpx + dgtq(1,1)  ! pressure 
         dragpy = dragpy + dgtq(2,1)
         dragpz = dragpz + dgtq(3,1)

         dragvx = dragvx + dgtq(1,2)  ! viscous
         dragvy = dragvy + dgtq(2,2)
         dragvz = dragvz + dgtq(3,2)

         torqpx = torqpx + dgtq(1,3)  ! pressure 
         torqpy = torqpy + dgtq(2,3)
         torqpz = torqpz + dgtq(3,3)

         torqvx = torqvx + dgtq(1,4)  ! viscous
         torqvy = torqvy + dgtq(2,4)
         torqvz = torqvz + dgtq(3,4)
      enddo
!
!     Sum contributions from all processors
!
      !call gop(dragpx,w1,'+  ',2)
      !call gop(dragpy,w1,'+  ',2)
      !call gop(dragpz,w1,'+  ',2)
      !call gop(dragvx,w1,'+  ',2)
      !call gop(dragvy,w1,'+  ',2)
      !call gop(dragvz,w1,'+  ',2)
!
      !call gop(torqpx,w1,'+  ',2)
      !call gop(torqpy,w1,'+  ',2)
      !call gop(torqpz,w1,'+  ',2)
      !call gop(torqvx,w1,'+  ',2)
      !call gop(torqvy,w1,'+  ',2)
      !call gop(torqvz,w1,'+  ',2)
      call MPI_Allreduce(MPI_IN_PLACE,dragpx, 1, &
         MPI_REAL_PRECISION, MPI_SUM, NEKO_COMM, ierr)
      call MPI_Allreduce(MPI_IN_PLACE,dragpy, 1, &
         MPI_REAL_PRECISION, MPI_SUM, NEKO_COMM, ierr)
      call MPI_Allreduce(MPI_IN_PLACE,dragpz, 1, &
         MPI_REAL_PRECISION, MPI_SUM, NEKO_COMM, ierr)
      call MPI_Allreduce(MPI_IN_PLACE,dragvx, 1, &
         MPI_REAL_PRECISION, MPI_SUM, NEKO_COMM, ierr)
      call MPI_Allreduce(MPI_IN_PLACE,dragvy, 1, &
         MPI_REAL_PRECISION, MPI_SUM, NEKO_COMM, ierr)
      call MPI_Allreduce(MPI_IN_PLACE,dragvz, 1, &
         MPI_REAL_PRECISION, MPI_SUM, NEKO_COMM, ierr)

      dragx = dragpx + dragvx
      dragy = dragpy + dragvy
      dragz = dragpz + dragvz

      torqx = torqpx + torqvx
      torqy = torqpy + torqvy
      torqz = torqpz + torqvz

      !dragpx(0) = dragpx (0) + dragpx (i)
      !dragvx(0) = dragvx (0) + dragvx (i)
      !dragx (0) = dragx  (0) + dragx  (i)

      !dragpy(0) = dragpy (0) + dragpy (i)
      !dragvy(0) = dragvy (0) + dragvy (i)
      !dragy (0) = dragy  (0) + dragy  (i)

      !dragpz(0) = dragpz (0) + dragpz (i)
      !dragvz(0) = dragvz (0) + dragvz (i)
      !dragz (0) = dragz  (0) + dragz  (i)

      !torqpx(0) = torqpx (0) + torqpx (i)
      !torqvx(0) = torqvx (0) + torqvx (i)
      !torqx (0) = torqx  (0) + torqx  (i)

      !torqpy(0) = torqpy (0) + torqpy (i)
      !torqvy(0) = torqvy (0) + torqvy (i)
      !torqy (0) = torqy  (0) + torqy  (i)

      !torqpz(0) = torqpz (0) + torqpz (i)
      !torqvz(0) = torqvz (0) + torqvz (i)
      !torqz (0) = torqz  (0) + torqz  (i)
      if (pe_rank .eq. 0) then
         write(*,*) tstep,dragx,dragpx,dragvx,'dragx'
         write(*,*) tstep,dragy,dragpy,dragvy,'dragy'
         write(*,*) tstep,dragz,dragpz,dragvz,'dragz'
      end if

  end subroutine

  subroutine drgtrq(dgtq,xm0,ym0,zm0,sij,pm1,visc,f,e, coef, Xh)
    type(coef_t) :: coef 
    type(space_t) :: Xh
    real(kind=rp) :: dgtq(3,4)
    real(kind=rp) :: xm0 (Xh%lx,xh%ly,Xh%lz,coef%msh%nelv)
    real(kind=rp) :: ym0 (Xh%lx,xh%ly,Xh%lz,coef%msh%nelv)
    real(kind=rp) :: zm0 (Xh%lx,xh%ly,Xh%lz,coef%msh%nelv)
    real(kind=rp) :: sij (Xh%lx,xh%ly,Xh%lz,6,coef%msh%nelv)
    real(kind=rp) :: pm1 (Xh%lx,xh%ly,Xh%lz,coef%msh%nelv)
    real(kind=rp) :: visc
    real(kind=rp) :: dg(3,2)
    integer :: f,e,pf,l, k, i, j1, j2
    real(kind=rp) ::    n1,n2,n3, j, a, r1, r2, r3, v
    integer :: skpdat(6,6), NX, NY, NZ
    integer :: js1   
    integer :: jf1   
    integer :: jskip1
    integer :: js2   
    integer :: jf2   
    integer :: jskip2
    real(kind=rp) :: s11, s21, s31, s12, s22, s32, s13, s23, s33


    NX = Xh%lx
    NY = Xh%ly
    NZ = Xh%lz
    SKPDAT(1,1)=1
    SKPDAT(2,1)=NX*(NY-1)+1
    SKPDAT(3,1)=NX
    SKPDAT(4,1)=1
    SKPDAT(5,1)=NY*(NZ-1)+1
    SKPDAT(6,1)=NY

    SKPDAT(1,2)=1             + (NX-1)
    SKPDAT(2,2)=NX*(NY-1)+1   + (NX-1)
    SKPDAT(3,2)=NX
    SKPDAT(4,2)=1
    SKPDAT(5,2)=NY*(NZ-1)+1
    SKPDAT(6,2)=NY

    SKPDAT(1,3)=1
    SKPDAT(2,3)=NX
    SKPDAT(3,3)=1
    SKPDAT(4,3)=1
    SKPDAT(5,3)=NY*(NZ-1)+1
    SKPDAT(6,3)=NY

    SKPDAT(1,4)=1           + NX*(NY-1)
    SKPDAT(2,4)=NX          + NX*(NY-1)
    SKPDAT(3,4)=1
    SKPDAT(4,4)=1
    SKPDAT(5,4)=NY*(NZ-1)+1
    SKPDAT(6,4)=NY

    SKPDAT(1,5)=1
    SKPDAT(2,5)=NX
    SKPDAT(3,5)=1
    SKPDAT(4,5)=1
    SKPDAT(5,5)=NY
    SKPDAT(6,5)=1

    SKPDAT(1,6)=1           + NX*NY*(NZ-1)
    SKPDAT(2,6)=NX          + NX*NY*(NZ-1)
    SKPDAT(3,6)=1
    SKPDAT(4,6)=1
    SKPDAT(5,6)=NY
    SKPDAT(6,6)=1
    pf = f
    js1    = skpdat(1,pf)
    jf1    = skpdat(2,pf)
    jskip1 = skpdat(3,pf)
    js2    = skpdat(4,pf)
    jf2    = skpdat(5,pf)
    jskip2 = skpdat(6,pf)
    call rzero(dgtq,12)
    i = 0
    a = 0
    do j2=js2,jf2,jskip2
       do j1=js1,jf1,jskip1
         i = i+1
         n1 = coef%nx(i,1,f,e)*coef%area(i,1,f,e)
         n2 = coef%ny(i,1,f,e)*coef%area(i,1,f,e)
         n3 = coef%nz(i,1,f,e)*coef%area(i,1,f,e)
         a  = a +          coef%area(i,1,f,e)
         v  = visc
         s11 = sij(j1,j2,1,1,e)
         s21 = sij(j1,j2,1,4,e)
         s31 = sij(j1,j2,1,6,e)
         s12 = sij(j1,j2,1,4,e)
         s22 = sij(j1,j2,1,2,e)
         s32 = sij(j1,j2,1,5,e)
         s13 = sij(j1,j2,1,6,e)
         s23 = sij(j1,j2,1,5,e)
         s33 = sij(j1,j2,1,3,e)
         dg(1,1) = pm1(j1,j2,1,e)*n1     ! pressure drag
         dg(2,1) = pm1(j1,j2,1,e)*n2
         dg(3,1) = pm1(j1,j2,1,e)*n3
         dg(1,2) = -v*(s11*n1 + s12*n2 + s13*n3) ! viscous drag
         dg(2,2) = -v*(s21*n1 + s22*n2 + s23*n3)
         dg(3,2) = -v*(s31*n1 + s32*n2 + s33*n3)
         r1 = xm0(j1,j2,1,e)
         r2 = ym0(j1,j2,1,e)
         r3 = zm0(j1,j2,1,e)
         do l=1,2
         do k=1,3
            dgtq(k,l) = dgtq(k,l) + dg(k,l)
         enddo
         enddo
         dgtq(1,3) = dgtq(1,3) + (r2*dg(3,1)-r3*dg(2,1)) ! pressure
         dgtq(2,3) = dgtq(2,3) + (r3*dg(1,1)-r1*dg(3,1)) ! torque
         dgtq(3,3) = dgtq(3,3) + (r1*dg(2,1)-r2*dg(1,1))
         dgtq(1,4) = dgtq(1,4) + (r2*dg(3,2)-r3*dg(2,2)) ! viscous
         dgtq(2,4) = dgtq(2,4) + (r3*dg(1,2)-r1*dg(3,2)) ! torque
         dgtq(3,4) = dgtq(3,4) + (r1*dg(2,2)-r2*dg(1,2))
       enddo
    enddo
  end

  subroutine comp_sij(sij,nij,u,v,w, Xh, coef)
!                                       du_i       du_j
!     Compute the stress tensor S_ij := ----   +   ----
!                                       du_j       du_i
!
      type(space_t) :: Xh
      type(coef_t) :: coef
      integer :: nij, e, i, nxyz, nelv
      real(kind=rp), intent(inout) :: sij(Xh%lxyz,nij,coef%msh%nelv)
      real(kind=rp), intent(in) :: u  (Xh%lxyz,coef%msh%nelv)
      real(kind=rp), intent(in) :: v  (Xh%lxyz,coef%msh%nelv)
      real(kind=rp), intent(in) :: w  (Xh%lxyz,coef%msh%nelv)
      real(kind=rp), dimension(Xh%lxyz) :: ur, us , ut&
        , vr, vs, vt&
        , wr, ws, wt
      real(kind=rp) j ! Inverse Jacobian
      integer :: N

      nelv = coef%msh%nelv
      N    = Xh%lx-1      ! Polynomial degree
      nxyz = Xh%lxyz
       do e=1,nelv
        call local_grad3(ur,us,ut,u,N,e,Xh%dx,Xh%dxt)
        call local_grad3(vr,vs,vt,v,N,e,Xh%dx,Xh%dxt)
        call local_grad3(wr,ws,wt,w,N,e,Xh%dx,Xh%dxt)

        do i=1,nxyz

         j = coef%jacinv(i,1,1,e)

         sij(i,1,e) = j* & ! du/dx + du/dx
        2*(ur(i)*coef%drdx(i,1,1,e)+us(i)*coef%dsdx(i,1,1,e)+ut(i)*coef%dtdx(i,1,1,e))

         sij(i,2,e) = j* & ! dv/dy + dv/dy
        2*(vr(i)*coef%drdy(i,1,1,e)+vs(i)*coef%dsdy(i,1,1,e)+vt(i)*coef%dtdy(i,1,1,e))

         sij(i,3,e) = j* & ! dw/dz + dw/dz
        2*(wr(i)*coef%drdz(i,1,1,e)+ws(i)*coef%dsdz(i,1,1,e)+wt(i)*coef%dtdz(i,1,1,e))

         sij(i,4,e) = j* & ! du/dy + dv/dx
        (ur(i)*coef%drdy(i,1,1,e)+us(i)*coef%dsdy(i,1,1,e)+ut(i)*coef%dtdy(i,1,1,e) +&
         vr(i)*coef%drdx(i,1,1,e)+vs(i)*coef%dsdx(i,1,1,e)+vt(i)*coef%dtdx(i,1,1,e) )

         sij(i,5,e) = j*&  ! dv/dz + dw/dy
        (wr(i)*coef%drdy(i,1,1,e)+ws(i)*coef%dsdy(i,1,1,e)+wt(i)*coef%dtdy(i,1,1,e) +&
         vr(i)*coef%drdz(i,1,1,e)+vs(i)*coef%dsdz(i,1,1,e)+vt(i)*coef%dtdz(i,1,1,e) )

         sij(i,6,e) = j* & ! du/dz + dw/dx
        (ur(i)*coef%drdz(i,1,1,e)+us(i)*coef%dsdz(i,1,1,e)+ut(i)*coef%dtdz(i,1,1,e) +&
         wr(i)*coef%drdx(i,1,1,e)+ws(i)*coef%dsdx(i,1,1,e)+wt(i)*coef%dtdx(i,1,1,e) )

        enddo
       enddo
   end subroutine comp_sij
   subroutine local_grad3(ur,us,ut,u,N,e,D,Dt)
      real(kind=rp) :: ur(0:N,0:N,0:N),us(0:N,0:N,0:N),ut(0:N,0:N,0:N)
      real(kind=rp) :: u (0:N,0:N,0:N,1)
      real(kind=rp) :: D (0:N,0:N),Dt(0:N,0:N)
      integer e, N,k, m1, m2
      m1 = N+1
      m2 = m1*m1
      call mxm(D ,m1,u(0,0,0,e),m1,ur,m2)
      do k=0,N
         call mxm(u(0,0,k,e),m1,Dt,m1,us(0,0,k),m1)
      enddo
      call mxm(u(0,0,0,e),m2,Dt,m1,ut,m1)
      return
