
!  +++++++++++++++++++++++ CC_SCALARS_IBM ++++++++++++++++++++++++++


! Routines related to cut-cells, scalar transport and immersed boundary methods
!
MODULE CC_SCALARS_IBM

USE COMPLEX_GEOMETRY
USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_VARIABLES
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: CURRENT_TIME, GET_FILE_NUMBER
USE MATH_FUNCTIONS, ONLY: SCALAR_FACE_VALUE

IMPLICIT NONE (TYPE,EXTERNAL)

LOGICAL, PARAMETER :: NEW_SCALAR_TRANSPORT = .TRUE.

! Debug Flags:
LOGICAL, PARAMETER :: DEBUG_IBM_INTERPOLATION=.FALSE. ! IBM interpolation and forcing scheme.
LOGICAL, PARAMETER :: DEBUG_MATVEC_DATA=.FALSE.  ! Cut-cell region indexing, construction of regular, rc faces for scalars, etc.
LOGICAL, PARAMETER :: DEBUG_CCREGION_SCALAR_TRANSPORT=.FALSE. ! Time integration algorithms for scalar tranport in cut-cell region.
LOGICAL, PARAMETER :: TIME_CC_IBM=.FALSE. ! Enable timers for main CC_IBM routines. Time stepping wall times in CHID_cc_cpu.csv
INTEGER :: LU_DB_CCIB

! Local integers:
INTEGER, SAVE :: ILO_CELL,IHI_CELL,JLO_CELL,JHI_CELL,KLO_CELL,KHI_CELL
INTEGER, SAVE :: ILO_FACE,IHI_FACE,JLO_FACE,JHI_FACE,KLO_FACE,KHI_FACE
INTEGER, SAVE :: NXB, NYB, NZB
INTEGER, SAVE :: X1LO_FACE,X1LO_CELL,X1HI_FACE,X1HI_CELL, &
                 X2LO_FACE,X2LO_CELL,X2HI_FACE,X2HI_CELL, &
                 X3LO_FACE,X3LO_CELL,X3HI_FACE,X3HI_CELL

! Allocatable real arrays
! Grid position containers:
REAL(EB), SAVE, TARGET, ALLOCATABLE, DIMENSION(:) :: XFACE,YFACE,ZFACE,XCELL,YCELL,ZCELL, &
          DXFACE,DYFACE,DZFACE,DXCELL,DYCELL,DZCELL,X1FACE,X2FACE,X3FACE,  &
          X2CELL,X3CELL,DX1FACE,DX2FACE,DX3FACE,DX2CELL,DX3CELL ! X1CELL,DX1CELL not used.

REAL(EB), POINTER, DIMENSION(:) :: X1FACEP,X2FACEP,X3FACEP,  &
                   X2CELLP,X3CELLP ! X1CELLP,DX1FACEP,DX2FACEP,DX3FACEP,DX1CELLP,DX2CELLP,DX3CELLP not used.

! Scalar transport variables:
INTEGER, PARAMETER :: FLX_LO=-2, FLX_HI=1
REAL(EB), SAVE :: BRP1 = 0._EB ! If 0., Godunov for advective term; if 1., centered interp.

INTEGER, ALLOCATABLE, DIMENSION(:) :: NUNKZ_LOC, NUNKZ_TOT, UNKZ_IND, UNKZ_ILC
INTEGER :: NUNKZ_LOCAL,NUNKZ_TOTAL

INTEGER, PARAMETER :: NNZ_ROW_Z = 15 ! 7 point stencil + 8 (buffer in case of unstructured grid).

INTEGER, ALLOCATABLE, DIMENSION(:)    :: NNZ_D_MAT_Z
INTEGER, ALLOCATABLE, DIMENSION(:,:)  :: JD_MAT_Z

REAL(EB),ALLOCATABLE, DIMENSION(:)   :: M_MAT_Z
INTEGER, ALLOCATABLE, DIMENSION(:)   :: JM_MAT_Z

REAL(EB), ALLOCATABLE, DIMENSION(:)  :: F_Z, RZ_Z, RZ_ZS
REAL(EB), ALLOCATABLE, DIMENSION(:,:):: F_Z0, RZ_Z0


! Forcing control logicals:
LOGICAL, PARAMETER :: FORCE_GAS_FACE      = .TRUE.

LOGICAL, SAVE :: CC_INJECT_RHO0 = .FALSE. ! .TRUE.: inject RHO0 and use Boundary W velocity for cut-cell centroid.
                                          ! .FALSE.: Interpolate RHO0 and W velocity to cut-cell centroid.
                                          ! Set to .TRUE. if &MISC CC_ZEROIBM_VELO=.TRUE.
LOGICAL, SAVE :: CC_INTERPOLATE_H=.TRUE.  ! Set to .FALSE. if &MISC CC_ZEROIBM_VELO=.TRUE.

!! Initial volume integral of species mass, for CHECK_MASS_CONSERVE
REAL(EB), ALLOCATABLE, DIMENSION(:) :: VOLINT_SPEC_MASS_0,FLXTINT_SPEC_MASS,VOLINT_SPEC_MASS


! Rotated Cube verification case wave number:
! 1 , SPEC ID=MY BACKGROUND
! 2 , SPEC ID=NEUMANN SPEC
INTEGER,  PARAMETER :: N_SPEC_BACKG = 1
INTEGER,  PARAMETER :: N_SPEC_NEUMN = 2
REAL(EB), PARAMETER :: GAM = PI/2._EB, AMP_Z=0.1_EB, MEAN_Z=0.15_EB
REAL(EB), PARAMETER :: NWAVE = 1._EB
REAL(EB), PARAMETER :: DISPXY(1:2,1) = RESHAPE((/ -PI/2._EB, -PI/2._EB /),(/2,1/))
REAL(EB), PARAMETER :: DISPL  = PI
REAL(EB) :: ROTANG, ROTMAT(2,2), TROTMAT(2,2)

PRIVATE

PUBLIC :: ADD_INPLACE_NNZ_H_WHLDOM,CALL_FOR_GLMAT,CALL_FROM_GLMAT_SETUP,CCCOMPUTE_RADIATION,&
          CCREGION_DIVERGENCE_PART_1,CCIBM_CHECK_DIVERGENCE,CCIBM_COMPUTE_VELOCITY_ERROR, &
          CCIBM_END_STEP,CCIBM_H_INTERP,CCIBM_INTERP_FACE_VEL,CCIBM_NO_FLUX, &
          CCIBM_RHO0W_INTERP,CCIBM_SET_DATA,CCIBM_TARGET_VELOCITY,CCIBM_VELOCITY_BC,CCIBM_VELOCITY_CUTFACES,CCIBM_VELOCITY_FLUX, &
          CCIBM_VELOCITY_NO_GRADH,CCREGION_DENSITY,CCREGION_COMPUTE_VISCOSITY,ADD_Q_DOT_CUTCELLS,CFACE_THERMAL_GASVARS,&
          CFACE_PREDICT_NORMAL_VELOCITY,CHECK_SPEC_TRANSPORT_CONSERVE,COPY_CC_UNKH_TO_HS, COPY_CC_HS_TO_UNKH, &
          GET_H_CUTFACES,GET_H_MATRIX_CC,GET_CRTCFCC_INT_STENCILS,GET_RCFACES_H, &
          GET_CC_MATRIXGRAPH_H,GET_CC_IROW,GET_CC_UNKH,GET_CUTCELL_FH,GET_CUTCELL_HP,&
          GET_PRES_CFACE, GET_PRES_CFACE_TEST, GET_UVWGAS_CFACE, GET_MUDNS_CFACE, GET_BOUNDFACE_GEOM_INFO_H, &
          FINISH_CCIBM, INIT_CUTCELL_DATA,LINEARFIELDS_INTERP_TEST,MASS_CONSERVE_INIT,MESH_CC_EXCHANGE,&
          NUMBER_UNKH_CUTCELLS,POTENTIAL_FLOW_INIT,&
          ROTATED_CUBE_ANN_SOLN,ROTATED_CUBE_VELOCITY_FLUX,ROTATED_CUBE_RHS_ZZ,&
          SET_DOMAINDIFFLX_3D,SET_DOMAINADVFLX_3D,SET_EXIMADVFLX_3D,SET_EXIMDIFFLX_3D,SET_EXIMRHOHSLIM_3D,SET_EXIMRHOZZLIM_3D

CONTAINS

! --------------------------- CC_EXCHANGE_UNPACKING_ARRAYS --------------------------

SUBROUTINE CC_EXCHANGE_UNPACKING_ARRAYS()

! Local Variables:
! Local Variables:
INTEGER :: NM,NOM,NOOM,IFEP,ICF,IFACE,ICD_SGN
TYPE (MESH_TYPE), POINTER :: M
TYPE (OMESH_TYPE), POINTER :: M2
INTEGER :: EP,INPE,INT_NPE_LO,INT_NPE_HI,VIND,IFACE_START,IEDGE

RECV_MESH_LOOP: DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   IF (EVACUATION_ONLY(NOM)) CYCLE RECV_MESH_LOOP
   M =>MESHES(NOM)

   SEND_MESH_LOOP: DO NM=1,NMESHES

      M2=>MESHES(NOM)%OMESH(NM)
      IF (EVACUATION_ONLY(NM)) CYCLE SEND_MESH_LOOP

      ! Boundary and gasphase cut-faces and rcedges, face centered variables for interpolation:
      CF_FC_IF : IF(M2%NFCC_R(1)>0) THEN
         ! Count:
         DO ICF=1,M%N_CUTFACE_MESH
            IFACE_START=1
            IF (M%CUT_FACE(ICF)%STATUS == IBM_GASPHASE) IFACE_START=0
            DO IFACE=IFACE_START,M%CUT_FACE(ICF)%NFACE
               DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                  DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                     INT_NPE_LO = M%CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
                     INT_NPE_HI = M%CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
                     DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                        NOOM   = M%CUT_FACE(ICF)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                        M2%NFEP_R(1) = M2%NFEP_R(1) + 1
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO
         ENDDO
         IF (M2%NFEP_R(1) > 0) THEN
            ! Allocate:
            IF (ALLOCATED(M2%IFEP_R_1)) DEALLOCATE(M2%IFEP_R_1)
            ALLOCATE(M2%IFEP_R_1(LOW_IND:HIGH_IND,M2%NFEP_R(1))); M2%IFEP_R_1 = IBM_UNDEFINED
            ! Add index entries:
            ! First Gasphase Cut-faces:
            IFEP = 0; IFACE_START=0
            DO ICF=1,M%N_CUTFACE_MESH
               IF (M%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE
               DO IFACE=IFACE_START,M%CUT_FACE(ICF)%NFACE
                  DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                     DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                        INT_NPE_LO = M%CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
                        INT_NPE_HI = M%CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
                        DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                           NOOM   = M%CUT_FACE(ICF)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                           IFEP = IFEP + 1
                           M2%IFEP_R_1( LOW_IND:HIGH_IND,IFEP) = (/ ICF, INPE /)
                        ENDDO
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO
            ! Store INPE points associated to Gasphase cut-faces:
            M2%NFEP_R_G = IFEP; IFACE_START=1
            ! Then boundary CFACEs:
            DO ICF=1,M%N_CUTFACE_MESH
               IF (M%CUT_FACE(ICF)%STATUS /= IBM_INBOUNDARY) CYCLE
               DO IFACE=IFACE_START,M%CUT_FACE(ICF)%NFACE
                  DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                     DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                        INT_NPE_LO = M%CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
                        INT_NPE_HI = M%CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
                        DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                           NOOM   = M%CUT_FACE(ICF)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                           IFEP = IFEP + 1
                           M2%IFEP_R_1( LOW_IND:HIGH_IND,IFEP) = (/ ICF, INPE /)
                        ENDDO
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO
         ENDIF

         ! Then RCEDGES:
         ! Count:
         DO IEDGE=1,M%IBM_NRCEDGE
            DO EP=1,INT_N_EXT_PTS  ! External point for face IEDGE
               DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                  INT_NPE_LO = M%IBM_RCEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,0)
                  INT_NPE_HI = M%IBM_RCEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,0)
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     NOOM   = M%IBM_RCEDGE(IEDGE)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                     M2%NFEP_R(3) = M2%NFEP_R(3) + 1
                  ENDDO
               ENDDO
            ENDDO
         ENDDO
         IF (M2%NFEP_R(3) > 0) THEN
            ! Allocate:
            IF (ALLOCATED(M2%IFEP_R_3)) DEALLOCATE(M2%IFEP_R_3)
            ALLOCATE(M2%IFEP_R_3(LOW_IND:HIGH_IND,M2%NFEP_R(3))); M2%IFEP_R_3 = IBM_UNDEFINED
            ! Add index entries:
            IFEP = 0
            DO IEDGE=1,M%IBM_NRCEDGE
               DO EP=1,INT_N_EXT_PTS  ! External point for face IEDGE
                  DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                     INT_NPE_LO = M%IBM_RCEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,0)
                     INT_NPE_HI = M%IBM_RCEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,0)
                     DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                        NOOM   = M%IBM_RCEDGE(IEDGE)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                        IFEP = IFEP + 1
                        M2%IFEP_R_3( LOW_IND:HIGH_IND,IFEP) = (/ IEDGE, INPE /)
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO
         ENDIF

         ! Then IBEDGES:
         ! Count:
         IF(CC_STRESS_METHOD) THEN
            DO IEDGE=1,M%IBM_NIBEDGE
               DO ICD_SGN=-2,2
                  IF(ICD_SGN==0) CYCLE
                  DO EP=1,INT_N_EXT_PTS  ! External point for face IEDGE
                     DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                       INT_NPE_LO = M%IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
                       INT_NPE_HI = M%IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
                       DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                          NOOM   = M%IBM_IBEDGE(IEDGE)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                          M2%NFEP_R(4) = M2%NFEP_R(4) + 1
                       ENDDO
                    ENDDO
                  ENDDO
               ENDDO
            ENDDO
         ENDIF
         IF (M2%NFEP_R(4) > 0) THEN
            ! Allocate:
            IF (ALLOCATED(M2%IFEP_R_4)) DEALLOCATE(M2%IFEP_R_4)
            ALLOCATE(M2%IFEP_R_4(LOW_IND:HIGH_IND,M2%NFEP_R(4))); M2%IFEP_R_4 = IBM_UNDEFINED
            IF(CC_STRESS_METHOD) THEN
               ! Add index entries:
               IFEP = 0
               DO IEDGE=1,M%IBM_NIBEDGE
                  DO ICD_SGN=-2,2
                     IF(ICD_SGN==0) CYCLE
                     DO EP=1,INT_N_EXT_PTS  ! External point for face IEDGE
                        DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                           INT_NPE_LO = M%IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
                           INT_NPE_HI = M%IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
                           DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                              NOOM   = M%IBM_IBEDGE(IEDGE)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                              IFEP = IFEP + 1
                              M2%IFEP_R_4( LOW_IND:HIGH_IND,IFEP) = (/ IEDGE, INPE /)
                           ENDDO
                        ENDDO
                     ENDDO
                  ENDDO
               ENDDO
            ENDIF
         ENDIF
      ENDIF CF_FC_IF

      ! Boundary cut-faces, cell centered variables for interpolation:
      BNDCF_CC_IF : IF(M2%NFCC_R(2)>0) THEN
         VIND = 0 ! Cell centered variables.
         ! Count:
         DO ICF=1,M%N_CUTFACE_MESH
            IF (M%CUT_FACE(ICF)%STATUS /= IBM_INBOUNDARY) CYCLE
            DO IFACE=1,M%CUT_FACE(ICF)%NFACE
               DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                  INT_NPE_LO = M%CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
                  INT_NPE_HI = M%CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     NOOM   = M%CUT_FACE(ICF)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                     M2%NFEP_R(2) = M2%NFEP_R(2) + 1
                  ENDDO
               ENDDO
            ENDDO
         ENDDO
         IF (M2%NFEP_R(2) > 0) THEN
            ! Allocate:
            IF (ALLOCATED(M2%IFEP_R_2)) DEALLOCATE(M2%IFEP_R_2)
            ALLOCATE(M2%IFEP_R_2(LOW_IND:HIGH_IND,M2%NFEP_R(2))); M2%IFEP_R_2 = IBM_UNDEFINED
            ! Add index entries:
            IFEP = 0
            DO ICF=1,M%N_CUTFACE_MESH
               IF (M%CUT_FACE(ICF)%STATUS /= IBM_INBOUNDARY) CYCLE
               DO IFACE=1,M%CUT_FACE(ICF)%NFACE
                  DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                     INT_NPE_LO = M%CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
                     INT_NPE_HI = M%CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
                     DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                        NOOM = M%CUT_FACE(ICF)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                        IFEP = IFEP + 1
                        M2%IFEP_R_2( LOW_IND:HIGH_IND,IFEP) = (/ ICF, INPE /)
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO
         ENDIF
         ! Case of IBEDGES:
         IF(CC_STRESS_METHOD) THEN
            ! Count:
            DO IEDGE=1,M%IBM_NIBEDGE
               DO ICD_SGN=-2,2
                  IF(ICD_SGN==0) CYCLE
                  DO EP=1,INT_N_EXT_PTS  ! External point for face IEDGE
                     INT_NPE_LO = M%IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
                     INT_NPE_HI = M%IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
                     DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                        NOOM   = M%IBM_IBEDGE(IEDGE)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                        M2%NFEP_R(5) = M2%NFEP_R(5) + 1
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO
            IF (M2%NFEP_R(5)>0) THEN
               ! Allocate:
               IF (ALLOCATED(M2%IFEP_R_5)) DEALLOCATE(M2%IFEP_R_5)
               ALLOCATE(M2%IFEP_R_5(LOW_IND:HIGH_IND,M2%NFEP_R(5))); M2%IFEP_R_5 = IBM_UNDEFINED
               ! Add index entries:
               IFEP = 0
               DO IEDGE=1,M%IBM_NIBEDGE
                  DO ICD_SGN=-2,2
                     IF(ICD_SGN==0) CYCLE
                     DO EP=1,INT_N_EXT_PTS  ! External point for face IEDGE
                        INT_NPE_LO = M%IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
                        INT_NPE_HI = M%IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
                        DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                           NOOM   = M%IBM_IBEDGE(IEDGE)%INT_NOMIND( LOW_IND,INPE); IF (NOOM /= NM) CYCLE
                           IFEP = IFEP + 1
                           M2%IFEP_R_5( LOW_IND:HIGH_IND,IFEP) = (/ IEDGE, INPE /)
                        ENDDO
                     ENDDO
                  ENDDO
               ENDDO
            ENDIF
         ENDIF
      ENDIF BNDCF_CC_IF
   ENDDO SEND_MESH_LOOP
ENDDO RECV_MESH_LOOP

RETURN
END SUBROUTINE CC_EXCHANGE_UNPACKING_ARRAYS



! ------------------------------- MESH_CC_EXCHANGE ---------------------------------

SUBROUTINE MESH_CC_EXCHANGE(CODE)

USE MPI_F08

INTEGER, INTENT(IN) :: CODE

! Local Variables:
INTEGER :: NM,NOM,RNODE,SNODE,IERR
INTEGER :: II1,JJ1,KK1,NCELL,ICC,ICC1,NQT2,JCC,LL,NN
INTEGER :: I,J,K,IFC,ICF,X1AXIS
TYPE (MESH_TYPE), POINTER :: M,M1
TYPE (OMESH_TYPE), POINTER :: M2,M3
LOGICAL, SAVE :: INITIALIZE_CC_SCALARS_FORC=.TRUE.

INTEGER :: EP,INPE,INT_NPE_LO,INT_NPE_HI,VIND,ICELL,IEDGE,IFEP,IW,IIO,JJO,KKO
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC
REAL(EB) :: TNOW

! In case of initialization code from main return.
! Initialization of cut-cell communications needs to be done later in the main.f90 sequence and will be done using
! INITIALIZE_CC_SCALARS/VELOCITY logicals.
IF (CODE == 0 .OR. CODE==2 .OR. CODE>6) RETURN
! No need to do mesh exchange within pressure iteration scheme here, when no IBM forcing, or call to fill GLMAT H ghost cells.
! Target velocity update is done at most twice in pressure iteration.
IF (CODE == 5 .AND. (CC_STRESS_METHOD .OR. PRESSURE_ITERATIONS>1 .OR. CALL_FOR_GLMAT)) RETURN
IF (.NOT.CC_MATVEC_DEFINED) RETURN
IF (CODE == 3 .AND. CALL_FROM_GLMAT_SETUP) RETURN

TNOW = CURRENT_TIME()

! First Allocate and setup persistent send-receives for scalars:
INITIALIZE_CC_SCALARS_FORC_COND : IF (INITIALIZE_CC_SCALARS_FORC) THEN

   ! Allocate REQ11, for scalar transport quantities, reduced cycling conditionals:
   N_REQ11=0
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      DO NOM=1,NMESHES
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NICC_S(1)==0 .AND. M3%NICC_R(1)==0) CYCLE
         N_REQ11 = N_REQ11+1
      ENDDO
   ENDDO
   ALLOCATE(REQ11(N_REQ11*4)); N_REQ11=0

   ! Allocate REQ12, for IBM forcing (face) quantities:
   N_REQ12=0
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      DO NOM=1,NMESHES
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NFCC_S(1)==0 .AND. M3%NFCC_R(1)==0) CYCLE
         N_REQ12 = N_REQ12+1
      ENDDO
   ENDDO
   ALLOCATE(REQ12(N_REQ12*4)); N_REQ12=0

   ! Allocate REQ13, for end of step H and RHO_0*W interpolation (cell) quantities:
   N_REQ13=0
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      DO NOM=1,NMESHES
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NFCC_S(2)==0 .AND. M3%NFCC_R(2)==0) CYCLE
         N_REQ13 = N_REQ13+1
      ENDDO
   ENDDO
   ALLOCATE(REQ13(N_REQ13*4)); N_REQ13=0


   ! 1. Receives:
   MESH_LOOP_1: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

      IF (EVACUATION_ONLY(NM)) CYCLE MESH_LOOP_1
      RNODE = PROCESS(NM)

      ! REQ11:
      OTHER_MESH_LOOP_11: DO NOM=1,NMESHES
         IF (EVACUATION_ONLY(NOM)) CYCLE OTHER_MESH_LOOP_11
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NICC_R(1)==0) CYCLE OTHER_MESH_LOOP_11
         SNODE = PROCESS(NOM)
         IF (M3%NICC_R(1)>0) THEN
            ! Cell centered variables on cut-cells:
            ALLOCATE(M3%REAL_RECV_PKG11(M3%NICC_R(2)*(4+N_TOTAL_SCALARS)))
            IF (RNODE/=SNODE) THEN
               N_REQ11 = N_REQ11 + 1
               CALL MPI_RECV_INIT(M3%REAL_RECV_PKG11(1),SIZE(M3%REAL_RECV_PKG11),MPI_DOUBLE_PRECISION, &
                                  SNODE,NOM,MPI_COMM_WORLD,REQ11(N_REQ11),IERR)
            ENDIF
         ENDIF
      ENDDO OTHER_MESH_LOOP_11

      ! REQ12:
      OTHER_MESH_LOOP_12: DO NOM=1,NMESHES
         IF (EVACUATION_ONLY(NOM)) CYCLE OTHER_MESH_LOOP_12
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NFCC_R(1)==0) CYCLE OTHER_MESH_LOOP_12
         SNODE = PROCESS(NOM)
         ! Face centered variables Ux1, Fvx1, dHdx1:
         ALLOCATE(M3%REAL_RECV_PKG12(M3%NFCC_R(1) * 2))
         IF (RNODE/=SNODE) THEN
            N_REQ12 = N_REQ12 + 1
            CALL MPI_RECV_INIT(M3%REAL_RECV_PKG12(1),SIZE(M3%REAL_RECV_PKG12),MPI_DOUBLE_PRECISION, &
                               SNODE,NOM,MPI_COMM_WORLD,REQ12(N_REQ12),IERR)
         ENDIF
      ENDDO OTHER_MESH_LOOP_12

      ! REQ13:
      OTHER_MESH_LOOP_13: DO NOM=1,NMESHES
         IF (EVACUATION_ONLY(NOM)) CYCLE OTHER_MESH_LOOP_13
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NFCC_R(2)==0) CYCLE OTHER_MESH_LOOP_13
         SNODE = PROCESS(NOM)
         ! Cell centered variables:
         ALLOCATE(M3%REAL_RECV_PKG13(M3%NFCC_R(2)*(NQT2C+N_TRACKED_SPECIES)))
         IF (RNODE/=SNODE) THEN
            N_REQ13 = N_REQ13 + 1
            CALL MPI_RECV_INIT(M3%REAL_RECV_PKG13(1),SIZE(M3%REAL_RECV_PKG13),MPI_DOUBLE_PRECISION, &
                               SNODE,NOM,MPI_COMM_WORLD,REQ13(N_REQ13),IERR)
         ENDIF
      ENDDO OTHER_MESH_LOOP_13

   ENDDO MESH_LOOP_1

   ! 2. Sends:
   SENDING_MESH_LOOP_1: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

      IF (EVACUATION_ONLY(NM)) CYCLE SENDING_MESH_LOOP_1
      RNODE = PROCESS(NM)
      M =>MESHES(NM)

      ! REQ11:
      RECEIVING_MESH_LOOP_11: DO NOM=1,NMESHES
         IF (EVACUATION_ONLY(NOM)) CYCLE RECEIVING_MESH_LOOP_11
         M3=>MESHES(NM)%OMESH(NOM)
         SNODE = PROCESS(NOM)
         ! Initialize persistent send requests
         IF (M3%NICC_S(1)>0 .AND. RNODE/=SNODE) THEN
            ALLOCATE(M3%REAL_SEND_PKG11(M3%NICC_S(2)*(4+N_TOTAL_SCALARS)))
            N_REQ11 = N_REQ11 + 1
            CALL MPI_SEND_INIT(M3%REAL_SEND_PKG11(1),SIZE(M3%REAL_SEND_PKG11),MPI_DOUBLE_PRECISION, &
                               SNODE,NM,MPI_COMM_WORLD,REQ11(N_REQ11),IERR)
         ENDIF
      ENDDO RECEIVING_MESH_LOOP_11

      ! REQ12:
      RECEIVING_MESH_LOOP_12: DO NOM=1,NMESHES
         IF (EVACUATION_ONLY(NOM)) CYCLE RECEIVING_MESH_LOOP_12
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NFCC_S(1)==0)  CYCLE RECEIVING_MESH_LOOP_12
         SNODE = PROCESS(NOM)
         ! Initialize persistent send requests
         IF (M3%NFCC_S(1)>0 .AND. RNODE/=SNODE) THEN
            ALLOCATE(M3%REAL_SEND_PKG12(M3%NFCC_S(1) * 2))
            N_REQ12 = N_REQ12 + 1
            CALL MPI_SEND_INIT(M3%REAL_SEND_PKG12(1),SIZE(M3%REAL_SEND_PKG12),MPI_DOUBLE_PRECISION, &
                               SNODE,NM,MPI_COMM_WORLD,REQ12(N_REQ12),IERR)
         ENDIF
      ENDDO RECEIVING_MESH_LOOP_12

      ! REQ13:
      RECEIVING_MESH_LOOP_13: DO NOM=1,NMESHES
         IF (EVACUATION_ONLY(NOM)) CYCLE RECEIVING_MESH_LOOP_13
         M3=>MESHES(NM)%OMESH(NOM)
         IF (M3%NFCC_S(2)==0)  CYCLE RECEIVING_MESH_LOOP_13
         SNODE = PROCESS(NOM)
         ! Initialize persistent send requests
         IF (M3%NFCC_S(2)>0 .AND. RNODE/=SNODE) THEN
            ALLOCATE(M3%REAL_SEND_PKG13(M3%NFCC_S(2)*(NQT2C+N_TRACKED_SPECIES)))
            N_REQ13 = N_REQ13 + 1
            CALL MPI_SEND_INIT(M3%REAL_SEND_PKG13(1),SIZE(M3%REAL_SEND_PKG13),MPI_DOUBLE_PRECISION, &
                               SNODE,NM,MPI_COMM_WORLD,REQ13(N_REQ13),IERR)
         ENDIF
      ENDDO RECEIVING_MESH_LOOP_13

   ENDDO SENDING_MESH_LOOP_1

   INITIALIZE_CC_SCALARS_FORC = .FALSE.

ENDIF INITIALIZE_CC_SCALARS_FORC_COND


! Exchange Scalars in cut-cells:
SENDING_MESH_LOOP_2: DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   IF (EVACUATION_ONLY(NM)) CYCLE SENDING_MESH_LOOP_2
   M =>MESHES(NM)
   RECEIVING_MESH_LOOP_2: DO NOM=1,NMESHES

      M1=>MESHES(NOM)
      M3=>MESHES(NM)%OMESH(NOM)
      IF (EVACUATION_ONLY(NOM)) CYCLE RECEIVING_MESH_LOOP_2

      SNODE = PROCESS(NOM)
      RNODE = PROCESS(NM)

      ! Exchange of density and species mass fractions following the PREDICTOR update

      IF (CODE==1 .AND. M3%NICC_S(1)>0) THEN
         NQT2 = 4+N_TOTAL_SCALARS
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG11: DO ICC1=1,M3%NICC_S(1)
               ICC=M3%ICC_UNKZ_CC_S(ICC1)
               NCELL=M%CUT_CELL(ICC)%NCELL
               II1=M%CUT_CELL(ICC)%IJK(IAXIS)
               JJ1=M%CUT_CELL(ICC)%IJK(JAXIS)
               KK1=M%CUT_CELL(ICC)%IJK(KAXIS)
               DO JCC=1,NCELL
                  LL = LL + 1
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+1) = M%CUT_CELL(ICC)%RHOS(JCC)
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+2) = M%CUT_CELL(ICC)%TMP(JCC)
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+3) = M%CUT_CELL(ICC)%RSUM(JCC)
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+4) = M%CUT_CELL(ICC)%D(JCC)
                  DO NN=1,N_TOTAL_SCALARS
                     M3%REAL_SEND_PKG11(NQT2*(LL-1)+4+NN) = M%CUT_CELL(ICC)%ZZS(NN,JCC)
                  ENDDO
               ENDDO
            ENDDO PACK_REAL_SEND_PKG11
         ENDIF
      ENDIF

      ! Information for CFACEs:
      IF (CODE==1 .AND. M3%NFCC_S(2)>0) THEN
         NQT2 = NQT2C+N_TOTAL_SCALARS
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG213 : DO ICC=1,M3%NFCC_S(2)
               I     = M3%IIO_CC_S(ICC)
               J     = M3%JJO_CC_S(ICC)
               K     = M3%KKO_CC_S(ICC)
               LL = LL + 1
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+1) = M%HS(I,J,K)                            ! Prev H in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+2) = M%RHO_0(K)                             ! RHO_0 in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+3) = 0.5_EB*(M%W(I,J,K-1)+M%W(I,J,K))       ! Wcen^n in I,J,K.
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+4) = M%RHOS(I,J,K)                          ! RHO^*
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+5) = M%TMP(I,J,K)                           ! TMP^*
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+6) = M%RSUM(I,J,K)                          ! RSUM^*
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+7) = M%MU(I,J,K)                            ! MU^n
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+8) = M%MU_DNS(I,J,K)                        ! MU_DNS^n
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+NQT2C)= M%RHO(I,J,K)*(M%HS(I,J,K)-M%KRES(I,J,K)) ! Previous substep pressure.
               DO NN=1,N_TOTAL_SCALARS
                  M3%REAL_SEND_PKG13(NQT2*(LL-1)+NQT2C+NN)= M%ZZS(I,J,K,NN)
               ENDDO
            ENDDO PACK_REAL_SEND_PKG213
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG213: DO IFEP=1,M2%NFEP_R(2)
               ICF = M2%IFEP_R_2( LOW_IND,IFEP)
               INPE= M2%IFEP_R_2(HIGH_IND,IFEP)
               LL  = M1%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_CC_S(LL)
               J     = M3%JJO_CC_S(LL)
               K     = M3%KKO_CC_S(LL)
               M1%CUT_FACE(ICF)%INT_CVARS(    INT_H_IND,INPE)= M%HS(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(  INT_RHO_IND,INPE)= M%RHOS(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(  INT_TMP_IND,INPE)= M%TMP(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS( INT_RSUM_IND,INPE)= M%RSUM(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(   INT_MU_IND,INPE)= M%MU(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(INT_MUDNS_IND,INPE)= M%MU_DNS(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(    INT_P_IND,INPE)= M%RHO(I,J,K)*(M%HS(I,J,K)-M%KRES(I,J,K))
               DO NN=1,N_TOTAL_SCALARS
                  M1%CUT_FACE(ICF)%INT_CVARS(INT_P_IND+NN,INPE)=M%ZZS(I,J,K,NN)
               ENDDO
            ENDDO PACK_REAL_RECV_PKG213
         ENDIF
      ENDIF

      ! Exchange velocity, momentum rhs and previous substep dH/Dx1 for cut-faces, in PREDICTOR, IBM forcing:

      IF (CODE==5 .AND. PREDICTOR .AND. M3%NFCC_S(1)>0) THEN
         NQT2 = 2
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG12 : DO IFC=1,M3%NFCC_S(1)
               I     = M3%IIO_FC_S(IFC)
               J     = M3%JJO_FC_S(IFC)
               K     = M3%KKO_FC_S(IFC)
               X1AXIS= M3%AXS_FC_S(IFC)
               LL = LL + 1
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%FVX(I,J,K)                          ! FVX in x face I,J,K
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+2) = (M%H(I+1,J,K)-M%H(I,J,K))*M%RDXN(I)   ! dH/dx^n in I,J,K.
               CASE(JAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%FVY(I,J,K)                          ! FVY in y face I,J,K
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+2) = (M%H(I,J+1,K)-M%H(I,J,K))*M%RDYN(J)   ! dH/dy^n in I,J,K.
               CASE(KAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%FVZ(I,J,K)                          ! FVZ in z face I,J,K
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+2) = (M%H(I,J,K+1)-M%H(I,J,K))*M%RDZN(K)   ! dH/dz^n in I,J,K.
               END SELECT
            ENDDO PACK_REAL_SEND_PKG12
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG12: DO IFEP=1,M2%NFEP_R(1)
               ICF = M2%IFEP_R_1( LOW_IND,IFEP)
               INPE= M2%IFEP_R_1(HIGH_IND,IFEP)
               LL  = M1%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS(  INT_FV_IND,INPE) = M%FVX(I,J,K)                        ! FVX in x face I,J,K
                  M1%CUT_FACE(ICF)%INT_FVARS(INT_DHDX_IND,INPE) = (M%H(I+1,J,K)-M%H(I,J,K))*M%RDXN(I) ! dH/dx^n in I,J,K.
               CASE(JAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS(  INT_FV_IND,INPE) = M%FVY(I,J,K)                        ! FVY in y face I,J,K
                  M1%CUT_FACE(ICF)%INT_FVARS(INT_DHDX_IND,INPE) = (M%H(I,J+1,K)-M%H(I,J,K))*M%RDYN(J) ! dH/dy^n in I,J,K.
               CASE(KAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS(  INT_FV_IND,INPE) = M%FVZ(I,J,K)                        ! FVZ in z face I,J,K
                  M1%CUT_FACE(ICF)%INT_FVARS(INT_DHDX_IND,INPE) = (M%H(I,J,K+1)-M%H(I,J,K))*M%RDZN(K) ! dH/dz^n in I,J,K.
               END SELECT
            ENDDO PACK_REAL_RECV_PKG12
         ENDIF
      ENDIF

      ! Exchange Velocity at end of PREDICTOR: To be used in RCEDGEs estimation of OME_E, TAU_E next substep.
      IF (CODE==3 .AND. M3%NFCC_S(1)>0) THEN
         NQT2 = 1
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG121 : DO IFC=1,M3%NFCC_S(1)
               I     = M3%IIO_FC_S(IFC)
               J     = M3%JJO_FC_S(IFC)
               K     = M3%KKO_FC_S(IFC)
               X1AXIS= M3%AXS_FC_S(IFC)
               LL = LL + 1
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%US(I,J,K)                           ! U^* in x face I,J,K
               CASE(JAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%VS(I,J,K)                           ! V^* in y face I,J,K
               CASE(KAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%WS(I,J,K)                           ! W^* in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_SEND_PKG121
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG121: DO IFEP=1,M2%NFEP_R(1)
               ICF = M2%IFEP_R_1( LOW_IND,IFEP)
               INPE= M2%IFEP_R_1(HIGH_IND,IFEP)
               LL  = M1%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS( INT_VELS_IND,INPE) = M%US(I,J,K)               ! U^* in x face I,J,K
               CASE(JAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS( INT_VELS_IND,INPE) = M%VS(I,J,K)               ! V^* in y face I,J,K
               CASE(KAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS( INT_VELS_IND,INPE) = M%WS(I,J,K)               ! W^* in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_RECV_PKG121
            ! Second Loop cut-edges:
            PACK_REAL_RECV_PKG121E: DO IFEP=1,M2%NFEP_R(3)
               IEDGE= M2%IFEP_R_3( LOW_IND,IFEP)
               INPE = M2%IFEP_R_3(HIGH_IND,IFEP)
               LL   = M1%IBM_RCEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%US(I,J,K)               ! U^* in x face I,J,K
               CASE(JAXIS)
                  M1%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%VS(I,J,K)               ! V^* in y face I,J,K
               CASE(KAXIS)
                  M1%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%WS(I,J,K)               ! W^* in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_RECV_PKG121E
            PACK_REAL_RECV_PKG121EIB: DO IFEP=1,M2%NFEP_R(4)
               IEDGE= M2%IFEP_R_4( LOW_IND,IFEP)
               INPE = M2%IFEP_R_4(HIGH_IND,IFEP)
               LL   = M1%IBM_IBEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%US(I,J,K)               ! U^* in x face I,J,K
               CASE(JAXIS)
                  M1%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%VS(I,J,K)               ! V^* in y face I,J,K
               CASE(KAXIS)
                  M1%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%WS(I,J,K)               ! W^* in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_RECV_PKG121EIB
         ENDIF
      ENDIF

      ! Exchange of density and species mass fractions following the CORRECTOR update

      IF (CODE==4 .AND. M3%NICC_S(1)>0) THEN
         NQT2 = 4+N_TOTAL_SCALARS
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG111: DO ICC1=1,M3%NICC_S(1)
               ICC=M3%ICC_UNKZ_CC_S(ICC1)
               NCELL=M%CUT_CELL(ICC)%NCELL
               II1=M%CUT_CELL(ICC)%IJK(IAXIS)
               JJ1=M%CUT_CELL(ICC)%IJK(JAXIS)
               KK1=M%CUT_CELL(ICC)%IJK(KAXIS)
               DO JCC=1,NCELL
                  LL = LL + 1
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+1) = M%CUT_CELL(ICC)%RHO(JCC)
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+2) = M%CUT_CELL(ICC)%TMP(JCC)
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+3) = M%CUT_CELL(ICC)%RSUM(JCC)
                  M3%REAL_SEND_PKG11(NQT2*(LL-1)+4) = M%CUT_CELL(ICC)%DS(JCC)
                  DO NN=1,N_TOTAL_SCALARS
                     M3%REAL_SEND_PKG11(NQT2*(LL-1)+4+NN) = M%CUT_CELL(ICC)%ZZ(NN,JCC)
                  ENDDO
               ENDDO
            ENDDO PACK_REAL_SEND_PKG111
         ENDIF
      ENDIF

      ! Information for CFACEs:
      IF (CODE==4 .AND. M3%NFCC_S(2)>0) THEN
         NQT2 = NQT2C+N_TOTAL_SCALARS
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG313 : DO ICC=1,M3%NFCC_S(2)
               I     = M3%IIO_CC_S(ICC)
               J     = M3%JJO_CC_S(ICC)
               K     = M3%KKO_CC_S(ICC)
               LL = LL + 1
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+1) = M%H(I,J,K)                             ! Prev H in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+2) = M%RHO_0(K)                             ! RHO_0 in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+3) = 0.5_EB*(M%WS(I,J,K-1)+M%WS(I,J,K))     ! Wcen^* in I,J,K.
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+4) = M%RHO(I,J,K)                           ! RHO^n+1
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+5) = M%TMP(I,J,K)                           ! TMP^n+1
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+6) = M%RSUM(I,J,K)                          ! RSUM^n+1
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+7) = M%MU(I,J,K)                            ! MU^*
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+8) = M%MU_DNS(I,J,K)                        ! MU_DNS^*
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+NQT2C)= M%RHOS(I,J,K)*(M%H(I,J,K)-M%KRES(I,J,K)) ! Previous substep pressure.
               DO NN=1,N_TOTAL_SCALARS
                  M3%REAL_SEND_PKG13(NQT2*(LL-1)+NQT2C+NN)= M%ZZ(I,J,K,NN)
               ENDDO
            ENDDO PACK_REAL_SEND_PKG313
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG313: DO IFEP=1,M2%NFEP_R(2)
               ICF = M2%IFEP_R_2( LOW_IND,IFEP)
               INPE= M2%IFEP_R_2(HIGH_IND,IFEP)
               LL  = M1%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_CC_S(LL)
               J     = M3%JJO_CC_S(LL)
               K     = M3%KKO_CC_S(LL)
               M1%CUT_FACE(ICF)%INT_CVARS(    INT_H_IND,INPE)= M%H(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(  INT_RHO_IND,INPE)= M%RHO(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(  INT_TMP_IND,INPE)= M%TMP(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS( INT_RSUM_IND,INPE)= M%RSUM(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(   INT_MU_IND,INPE)= M%MU(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(INT_MUDNS_IND,INPE)= M%MU_DNS(I,J,K)
               M1%CUT_FACE(ICF)%INT_CVARS(    INT_P_IND,INPE)= M%RHOS(I,J,K)*(M%H(I,J,K)-M%KRES(I,J,K))
               DO NN=1,N_TOTAL_SCALARS
                  M1%CUT_FACE(ICF)%INT_CVARS(INT_P_IND+NN,INPE)=M%ZZ(I,J,K,NN)
               ENDDO
            ENDDO PACK_REAL_RECV_PKG313
         ENDIF
      ENDIF


      ! Exchange velocity, momentum rhs and previous substep dH/Dx1 for cut-faces, in CORRECTOR, IBM forcing:

      IF (CODE==5 .AND. CORRECTOR .AND. M3%NFCC_S(1)>0) THEN
         NQT2 = 2
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG112 : DO IFC=1,M3%NFCC_S(1)
               I     = M3%IIO_FC_S(IFC)
               J     = M3%JJO_FC_S(IFC)
               K     = M3%KKO_FC_S(IFC)
               X1AXIS= M3%AXS_FC_S(IFC)
               LL = LL + 1
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%FVX(I,J,K)                          ! FVX in x face I,J,K
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+2) = (M%HS(I+1,J,K)-M%HS(I,J,K))*M%RDXN(I) ! dH/dx^* in I,J,K.
               CASE(JAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%FVY(I,J,K)                          ! FVY in y face I,J,K
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+2) = (M%HS(I,J+1,K)-M%HS(I,J,K))*M%RDYN(J) ! dH/dy^* in I,J,K.
               CASE(KAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%FVZ(I,J,K)                          ! FVZ in z face I,J,K
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+2) = (M%HS(I,J,K+1)-M%HS(I,J,K))*M%RDZN(K) ! dH/dz^* in I,J,K.
               END SELECT
            ENDDO PACK_REAL_SEND_PKG112
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG112: DO IFEP=1,M2%NFEP_R(1)
               ICF = M2%IFEP_R_1( LOW_IND,IFEP)
               INPE= M2%IFEP_R_1(HIGH_IND,IFEP)
               LL  = M1%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS(  INT_FV_IND,INPE) = M%FVX(I,J,K)                          ! FVX in x face I,J,K
                  M1%CUT_FACE(ICF)%INT_FVARS(INT_DHDX_IND,INPE) = (M%HS(I+1,J,K)-M%HS(I,J,K))*M%RDXN(I) ! dH/dx^* in I,J,K.
               CASE(JAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS(  INT_FV_IND,INPE) = M%FVY(I,J,K)                          ! FVY in y face I,J,K
                  M1%CUT_FACE(ICF)%INT_FVARS(INT_DHDX_IND,INPE) = (M%HS(I,J+1,K)-M%HS(I,J,K))*M%RDYN(J) ! dH/dy^* in I,J,K.
               CASE(KAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS(  INT_FV_IND,INPE) = M%FVZ(I,J,K)                          ! FVZ in z face I,J,K
                  M1%CUT_FACE(ICF)%INT_FVARS(INT_DHDX_IND,INPE) = (M%HS(I,J,K+1)-M%HS(I,J,K))*M%RDZN(K) ! dH/dz^* in I,J,K.
               END SELECT
            ENDDO PACK_REAL_RECV_PKG112
         ENDIF
      ENDIF

      ! Exchange Velocity and Pressure at end of CORRECTOR: To be used in RCEDGEs estimation of OME_E, TAU_E next substep.
      IF (CODE==6 .AND. M3%NFCC_S(1)>0) THEN
         NQT2 = 1
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG122 : DO IFC=1,M3%NFCC_S(1)
               I     = M3%IIO_FC_S(IFC)
               J     = M3%JJO_FC_S(IFC)
               K     = M3%KKO_FC_S(IFC)
               X1AXIS= M3%AXS_FC_S(IFC)
               LL = LL + 1
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%U(I,J,K)                            ! U^n+1 in x face I,J,K
               CASE(JAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%V(I,J,K)                            ! V^n+1 in y face I,J,K
               CASE(KAXIS)
                  M3%REAL_SEND_PKG12(NQT2*(LL-1)+1) = M%W(I,J,K)                            ! W^n+1 in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_SEND_PKG122
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG122: DO IFEP=1,M2%NFEP_R(1)
               ICF = M2%IFEP_R_1( LOW_IND,IFEP)
               INPE= M2%IFEP_R_1(HIGH_IND,IFEP)
               LL  = M1%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS( INT_VEL_IND,INPE) = M%U(I,J,K)                ! U^n+1 in x face I,J,K
               CASE(JAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS( INT_VEL_IND,INPE) = M%V(I,J,K)                ! V^n+1 in y face I,J,K
               CASE(KAXIS)
                  M1%CUT_FACE(ICF)%INT_FVARS( INT_VEL_IND,INPE) = M%W(I,J,K)                ! W^n+1 in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_RECV_PKG122
            ! Second Loop cut-edges:
            PACK_REAL_RECV_PKG122E: DO IFEP=1,M2%NFEP_R(3)
               IEDGE= M2%IFEP_R_3( LOW_IND,IFEP)
               INPE = M2%IFEP_R_3(HIGH_IND,IFEP)
               LL   = M1%IBM_RCEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%U(I,J,K)             ! U^n+1 in x face I,J,K
               CASE(JAXIS)
                  M1%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%V(I,J,K)             ! V^n+1 in y face I,J,K
               CASE(KAXIS)
                  M1%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%W(I,J,K)             ! W^n+1 in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_RECV_PKG122E
            PACK_REAL_RECV_PKG122EIB: DO IFEP=1,M2%NFEP_R(4)
               IEDGE= M2%IFEP_R_4( LOW_IND,IFEP)
               INPE = M2%IFEP_R_4(HIGH_IND,IFEP)
               LL   = M1%IBM_IBEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               I     = M3%IIO_FC_S(LL)
               J     = M3%JJO_FC_S(LL)
               K     = M3%KKO_FC_S(LL)
               X1AXIS= M3%AXS_FC_S(LL)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  M1%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%U(I,J,K)             ! U^n+1 in x face I,J,K
               CASE(JAXIS)
                  M1%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%V(I,J,K)             ! V^n+1 in y face I,J,K
               CASE(KAXIS)
                  M1%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE) = M%W(I,J,K)             ! W^n+1 in z face I,J,K
               END SELECT
            ENDDO PACK_REAL_RECV_PKG122EIB
         ENDIF
      ENDIF

      ! Exchange H, RHO_0 and W velocity averaged to cell center, at PREDICTOR end of step:

      IF (CODE==3 .AND. M3%NFCC_S(2)>0) THEN
         NQT2 = 4
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG13 : DO ICC=1,M3%NFCC_S(2)
               I     = M3%IIO_CC_S(ICC)
               J     = M3%JJO_CC_S(ICC)
               K     = M3%KKO_CC_S(ICC)
               LL = LL + 1
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+1) = M%H(I,J,K)                             ! H^n in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+2) = M%RHO_0(K)                             ! RHO_0 in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+3) = 0.5_EB*(M%WS(I,J,K-1)+M%WS(I,J,K))     ! Wcen^* in I,J,K.
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+4) = M%MU(I,J,K)                            ! MU in I,J,K
            ENDDO PACK_REAL_SEND_PKG13
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG13: DO ICC=1,M3%NFCC_S(2)
               I     = M3%IIO_CC_S(ICC)
               J     = M3%JJO_CC_S(ICC)
               K     = M3%KKO_CC_S(ICC)
               LL = LL + 1
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+1) = M%H(I,J,K)                             ! H^n in cell I,J,K
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+2) = M%RHO_0(K)                             ! RHO_0 in cell I,J,K
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+3) = 0.5_EB*(M%WS(I,J,K-1)+M%WS(I,J,K))     ! Wcen^* in I,J,K.
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+4) = M%MU(I,J,K)                            ! MU in I,J,K
            ENDDO PACK_REAL_RECV_PKG13
         ENDIF
      ENDIF

      ! Exchange H, RHO_0 and W velocity averaged to cell center, at CORRECTOR end of step:

      IF (CODE==6 .AND. M3%NFCC_S(2)>0) THEN
         NQT2 = 4
         LL = 0
         IF (RNODE/=SNODE) THEN
            PACK_REAL_SEND_PKG113 : DO ICC=1,M3%NFCC_S(2)
               I     = M3%IIO_CC_S(ICC)
               J     = M3%JJO_CC_S(ICC)
               K     = M3%KKO_CC_S(ICC)
               LL = LL + 1
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+1) = M%HS(I,J,K)                            ! H^* in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+2) = M%RHO_0(K)                             ! RHO_0 in cell I,J,K
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+3) = 0.5_EB*(M%W(I,J,K-1)+M%W(I,J,K))       ! Wcen  in I,J,K.
               M3%REAL_SEND_PKG13(NQT2*(LL-1)+4) = M%MU(I,J,K)                            ! MU in I,J,K
            ENDDO PACK_REAL_SEND_PKG113
         ELSE
            M2=>MESHES(NOM)%OMESH(NM)
            PACK_REAL_RECV_PKG113: DO ICC=1,M3%NFCC_S(2)
               I     = M3%IIO_CC_S(ICC)
               J     = M3%JJO_CC_S(ICC)
               K     = M3%KKO_CC_S(ICC)
               LL = LL + 1
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+1) = M%HS(I,J,K)                            ! H^* in cell I,J,K
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+2) = M%RHO_0(K)                             ! RHO_0 in cell I,J,K
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+3) = 0.5_EB*(M%W(I,J,K-1)+M%W(I,J,K))       ! Wcen  in I,J,K.
               M2%REAL_RECV_PKG13(NQT2*(LL-1)+4) = M%MU(I,J,K)                            ! MU in I,J,K
            ENDDO PACK_REAL_RECV_PKG113
         ENDIF
      ENDIF

   ENDDO RECEIVING_MESH_LOOP_2
ENDDO SENDING_MESH_LOOP_2

! Exchange Scalars:
IF (N_MPI_PROCESSES>1 .AND. (CODE==1.OR.CODE==4) .AND. N_REQ11>0) THEN
   CALL MPI_STARTALL(N_REQ11,REQ11(1:N_REQ11),IERR)
   CALL CC_TIMEOUT('REQ11',N_REQ11,REQ11(1:N_REQ11))
ENDIF

! Exchange IBM forcing data for gas cut-faces:
IF (N_MPI_PROCESSES>1 .AND. CODE==5 .AND. N_REQ12>0) THEN
   CALL MPI_STARTALL(N_REQ12,REQ12(1:N_REQ12),IERR)
   CALL CC_TIMEOUT('REQ12',N_REQ12,REQ12(1:N_REQ12))
ENDIF

! Exchange End of Step velocity data for RCEDGEs:
IF (N_MPI_PROCESSES>1 .AND. (CODE==3.OR.CODE==6) .AND. N_REQ12>0) THEN
   CALL MPI_STARTALL(N_REQ12,REQ12(1:N_REQ12),IERR)
   CALL CC_TIMEOUT('REQ12',N_REQ12,REQ12(1:N_REQ12))
ENDIF

! Exchange scalar data for CFACES, or End of step cell-centered data:
IF (N_MPI_PROCESSES>1 .AND. (CODE==1.OR.CODE==4.OR.CODE==3.OR.CODE==6) .AND. N_REQ13>0) THEN
   CALL MPI_STARTALL(N_REQ13,REQ13(1:N_REQ13),IERR)
   CALL CC_TIMEOUT('REQ13',N_REQ13,REQ13(1:N_REQ13))
ENDIF

! Receive the information sent above into the appropriate arrays.

RECV_MESH_LOOP: DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   IF (EVACUATION_ONLY(NOM)) CYCLE RECV_MESH_LOOP
   M =>MESHES(NOM)

   SEND_MESH_LOOP: DO NM=1,NMESHES

      M2=>MESHES(NOM)%OMESH(NM)
      IF (EVACUATION_ONLY(NM)) CYCLE SEND_MESH_LOOP

      RNODE = PROCESS(NOM)
      SNODE = PROCESS(NM)

      RNODE_SNODE_IF: IF (RNODE/=SNODE) THEN

         ! Unpack densities and species mass fractions following PREDICTOR exchange

         IF (CODE==1 .AND. M2%NICC_R(1)>0) THEN
            NQT2 = 4+N_TOTAL_SCALARS
            LL = 0
            ! Copy-cut cell scalar quantities from MESHES(NOM)%OMESH(NM) cells to MESHES(NM) (i.e. other mesh) cut-cells:
            ! Use External wall cell loop:
            EXTERNAL_WALL_LOOP_1 : DO IW=1,M%N_EXTERNAL_WALL_CELLS
               WC=>M%WALL(IW)
               EWC=>M%EXTERNAL_WALL(IW)
               IF (.NOT.(WC%BOUNDARY_TYPE == INTERPOLATED_BOUNDARY)) CYCLE EXTERNAL_WALL_LOOP_1
               IF (EWC%NOM/=NM) CYCLE EXTERNAL_WALL_LOOP_1
               IF (M%CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_CGSC) /= IBM_CUTCFE) CYCLE EXTERNAL_WALL_LOOP_1
               DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
                  DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
                     DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
                       ICC   = MESHES(NM)%CCVAR(IIO,JJO,KKO,IBM_IDCC)
                       IF (ICC > 0) THEN
                          DO JCC=1,MESHES(NM)%CUT_CELL(ICC)%NCELL
                             LL = LL + 1
                             MESHES(NM)%CUT_CELL(ICC)%RHOS(JCC) = M2%REAL_RECV_PKG11(NQT2*(LL-1)+1)
                             MESHES(NM)%CUT_CELL(ICC)%TMP(JCC)  = M2%REAL_RECV_PKG11(NQT2*(LL-1)+2)
                             MESHES(NM)%CUT_CELL(ICC)%RSUM(JCC) = M2%REAL_RECV_PKG11(NQT2*(LL-1)+3)
                             MESHES(NM)%CUT_CELL(ICC)%D(JCC)    = M2%REAL_RECV_PKG11(NQT2*(LL-1)+4)
                             DO NN=1,N_TOTAL_SCALARS
                                MESHES(NM)%CUT_CELL(ICC)%ZZS(NN,JCC) = M2%REAL_RECV_PKG11(NQT2*(LL-1)+4+NN)
                             ENDDO
                          ENDDO
                       ENDIF
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO EXTERNAL_WALL_LOOP_1
         ENDIF

         IF((CODE==1 .OR. CODE==4) .AND. M2%NFCC_R(2)>0) THEN
            NQT2 = NQT2C+N_TOTAL_SCALARS
            DO IFEP=1,M2%NFEP_R(2)
               ICF = M2%IFEP_R_2( LOW_IND,IFEP)
               INPE= M2%IFEP_R_2(HIGH_IND,IFEP)
               LL  = M%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               M%CUT_FACE(ICF)%INT_CVARS(    INT_H_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+1)
               M%CUT_FACE(ICF)%INT_CVARS(  INT_RHO_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+4)
               M%CUT_FACE(ICF)%INT_CVARS(  INT_TMP_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+5)
               M%CUT_FACE(ICF)%INT_CVARS( INT_RSUM_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+6)
               M%CUT_FACE(ICF)%INT_CVARS(   INT_MU_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+7)
               M%CUT_FACE(ICF)%INT_CVARS(INT_MUDNS_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+8)
               M%CUT_FACE(ICF)%INT_CVARS(    INT_P_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+NQT2C)
               DO NN=1,N_TOTAL_SCALARS
                  M%CUT_FACE(ICF)%INT_CVARS(INT_P_IND+NN,INPE)=M2%REAL_RECV_PKG13(NQT2*(LL-1)+NQT2C+NN)
               ENDDO
            ENDDO
         ENDIF

         ! Unpack velocity, momentum rhs and previous substep dH/Dx1 for cut-faces, in PREDICTOR or CORRECTOR, IBM forcing:

         IF (CODE==5  .AND. M2%NFCC_R(1)>0) THEN
            NQT2 = 2 ! Two variables are passed per Stencil point. Fv and DHDX1.
            DO IFEP=1,M2%NFEP_R_G ! Only Gasphase cut-faces:
               ICF = M2%IFEP_R_1( LOW_IND,IFEP);
               INPE= M2%IFEP_R_1(HIGH_IND,IFEP)
               LL  = M%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               M%CUT_FACE(ICF)%INT_FVARS(  INT_FV_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+1) ! Predictor FV
               M%CUT_FACE(ICF)%INT_FVARS(INT_DHDX_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+2) ! dH/dx1^n
            ENDDO
         ENDIF

         IF (CODE==3 .AND. M2%NFCC_R(1)>0) THEN
            NQT2 = 1
            ! First loop cut-faces:
            DO IFEP=1,M2%NFEP_R(1) ! Gasphase and Boundary cut-faces:
               ICF = M2%IFEP_R_1( LOW_IND,IFEP);
               INPE= M2%IFEP_R_1(HIGH_IND,IFEP)
               LL  = M%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               M%CUT_FACE(ICF)%INT_FVARS(INT_VELS_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+1) ! Vel^*
            ENDDO
            ! Second Loop cut-edges:
            DO IFEP=1,M2%NFEP_R(3)
               IEDGE= M2%IFEP_R_3( LOW_IND,IFEP)
               INPE = M2%IFEP_R_3(HIGH_IND,IFEP)
               LL   = M%IBM_RCEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               M%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+1) ! Vel^*, added to INT_VEL_IND pos.
            ENDDO
            DO IFEP=1,M2%NFEP_R(4)
               IEDGE= M2%IFEP_R_4( LOW_IND,IFEP)
               INPE = M2%IFEP_R_4(HIGH_IND,IFEP)
               LL   = M%IBM_IBEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               M%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+1) ! Vel^*, added to INT_VEL_IND pos.
            ENDDO
         ENDIF

         ! Unpack densities and species mass fractions following CORRECTOR exchange

         IF (CODE==4 .AND. M2%NICC_R(1)>0) THEN
            NQT2 = 4+N_TOTAL_SCALARS
            LL = 0
            ! Copy-cut cell scalar quantities from MESHES(NOM)%OMESH(NM) cells to MESHES(NM) (i.e. other mesh) cut-cells:
            ! Use External wall cell loop:
            EXTERNAL_WALL_LOOP_2 : DO IW=1,M%N_EXTERNAL_WALL_CELLS
               WC=>M%WALL(IW)
               IF (.NOT.(WC%BOUNDARY_TYPE == INTERPOLATED_BOUNDARY)) CYCLE EXTERNAL_WALL_LOOP_2
               EWC=>M%EXTERNAL_WALL(IW)
               IF (EWC%NOM/=NM) CYCLE EXTERNAL_WALL_LOOP_2
               IF (M%CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_CGSC) /= IBM_CUTCFE) CYCLE EXTERNAL_WALL_LOOP_2
               DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
                  DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
                     DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
                       ICC   = MESHES(NM)%CCVAR(IIO,JJO,KKO,IBM_IDCC)
                       IF (ICC > 0) THEN
                          DO JCC=1,MESHES(NM)%CUT_CELL(ICC)%NCELL
                             LL = LL + 1
                             MESHES(NM)%CUT_CELL(ICC)%RHO(JCC)  = M2%REAL_RECV_PKG11(NQT2*(LL-1)+1)
                             MESHES(NM)%CUT_CELL(ICC)%TMP(JCC)  = M2%REAL_RECV_PKG11(NQT2*(LL-1)+2)
                             MESHES(NM)%CUT_CELL(ICC)%RSUM(JCC) = M2%REAL_RECV_PKG11(NQT2*(LL-1)+3)
                             MESHES(NM)%CUT_CELL(ICC)%DS(JCC)   = M2%REAL_RECV_PKG11(NQT2*(LL-1)+4)
                             DO NN=1,N_TOTAL_SCALARS
                                MESHES(NM)%CUT_CELL(ICC)%ZZ(NN,JCC) = M2%REAL_RECV_PKG11(NQT2*(LL-1)+4+NN)
                             ENDDO
                          ENDDO
                       ENDIF
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO EXTERNAL_WALL_LOOP_2
         ENDIF

         IF (CODE==6 .AND. M2%NFCC_R(1)>0) THEN
            NQT2 = 1
            ! First loop cut-faces:
            DO IFEP=1,M2%NFEP_R(1) ! Gasphase and Boundary cut-faces:
               ICF = M2%IFEP_R_1( LOW_IND,IFEP);
               INPE= M2%IFEP_R_1(HIGH_IND,IFEP)
               LL  = M%CUT_FACE(ICF)%INT_NOMIND(HIGH_IND,INPE)
               M%CUT_FACE(ICF)%INT_FVARS(INT_VEL_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+1) ! Vel^n+1
            ENDDO
            ! Second Loop cut-edges:
            DO IFEP=1,M2%NFEP_R(3)
               IEDGE= M2%IFEP_R_3( LOW_IND,IFEP)
               INPE = M2%IFEP_R_3(HIGH_IND,IFEP)
               LL   = M%IBM_RCEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               M%IBM_RCEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+1) ! Vel^n+1
            ENDDO
            DO IFEP=1,M2%NFEP_R(4)
               IEDGE= M2%IFEP_R_4( LOW_IND,IFEP)
               INPE = M2%IFEP_R_4(HIGH_IND,IFEP)
               LL   = M%IBM_IBEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               M%IBM_IBEDGE(IEDGE)%INT_FVARS(INT_VEL_IND,INPE)= M2%REAL_RECV_PKG12(NQT2*(LL-1)+1) ! Vel^n+1
            ENDDO
         ENDIF

      ENDIF RNODE_SNODE_IF

      ! Unpack H, RHO_0 and W velocity averaged to cell center, at PREDICTOR or CORRECTOR end of step:

      IF ( (CODE==3 .OR. CODE==6) .AND. M2%NFCC_R(2)>0) THEN
         NQT2 = 4
         ! First loop cut-cells:
         VIND = 0
         DO ICC=1,M%N_CUTCELL_MESH
            DO ICELL=0,M%CUT_CELL(ICC)%NCELL
               DO EP=1,INT_N_EXT_PTS  ! External point for cell ICELL
                  INT_NPE_LO = M%CUT_CELL(ICC)%INT_NPE(LOW_IND,VIND,EP,ICELL)
                  INT_NPE_HI = M%CUT_CELL(ICC)%INT_NPE(HIGH_IND,VIND,EP,ICELL)
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     IF (M%CUT_CELL(ICC)%INT_NOMIND( LOW_IND,INPE) /= NM) CYCLE
                     LL     = M%CUT_CELL(ICC)%INT_NOMIND(HIGH_IND,INPE)
                     M%CUT_CELL(ICC)%INT_CCVARS(   INT_H_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+1) ! H^n, or H^s
                     M%CUT_CELL(ICC)%INT_CCVARS(INT_RHO0_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+2) ! RHO_0
                     M%CUT_CELL(ICC)%INT_CCVARS(INT_WCEN_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+3) ! Wcen^*, or Wcen^n+1
                  ENDDO
               ENDDO
            ENDDO
         ENDDO
         ! Then Loop IBEDGES if CC_STRESS_METHOD=.TRUE. add MU:
         IF (CC_STRESS_METHOD) THEN
            DO IFEP=1,M2%NFEP_R(5)
               IEDGE= M2%IFEP_R_5( LOW_IND,IFEP)
               INPE = M2%IFEP_R_5(HIGH_IND,IFEP)
               LL   = M%IBM_IBEDGE(IEDGE)%INT_NOMIND(HIGH_IND,INPE)
               M%IBM_IBEDGE(IEDGE)%INT_CVARS(INT_MU_IND,INPE)= M2%REAL_RECV_PKG13(NQT2*(LL-1)+4) ! MU.
            ENDDO
         ENDIF
      ENDIF

   ENDDO SEND_MESH_LOOP
ENDDO RECV_MESH_LOOP

IF(CODE==3 .OR. CODE==6) THEN
   CALL CCIBM_H_INTERP
   CALL CCIBM_RHO0W_INTERP
ENDIF

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(MESH_CC_EXCHANGE_TIME_INDEX) = T_CC_USED(MESH_CC_EXCHANGE_TIME_INDEX) + CURRENT_TIME() - TNOW

RETURN

CONTAINS

SUBROUTINE CC_TIMEOUT(RNAME,NR,RR)

REAL(EB) :: START_TIME,WAIT_TIME
INTEGER :: NR
TYPE (MPI_REQUEST), DIMENSION(:) :: RR
LOGICAL :: FLAG
CHARACTER(*) :: RNAME

IF (.NOT.PROFILING) THEN

   START_TIME = MPI_WTIME()
   FLAG = .FALSE.
   DO WHILE(.NOT.FLAG)
      CALL MPI_TESTALL(NR,RR(1:NR),FLAG,MPI_STATUSES_IGNORE,IERR)
      WAIT_TIME = MPI_WTIME() - START_TIME
      IF (WAIT_TIME>MPI_TIMEOUT) THEN
         WRITE(LU_ERR,'(A,A,A,I6,A,A)') 'CC_TIMEOUT Error: ',TRIM(RNAME),' timed out for MPI process ',MY_RANK
         CALL MPI_ABORT(MPI_COMM_WORLD,0,IERR)
      ENDIF
   ENDDO
ELSE

   CALL MPI_WAITALL(NR,RR(1:NR),MPI_STATUSES_IGNORE,IERR)

ENDIF

END SUBROUTINE CC_TIMEOUT

END SUBROUTINE MESH_CC_EXCHANGE


! ----------------------------- CCREGION_COMPUTE_VISCOSITY -------------------------

SUBROUTINE CCREGION_COMPUTE_VISCOSITY(DT,NM)

USE PHYSICAL_FUNCTIONS, ONLY: LES_FILTER_WIDTH_FUNCTION
USE TURBULENCE, ONLY: WALE_VISCOSITY
USE TURBULENCE, ONLY : WALL_MODEL

REAL(EB), INTENT(IN):: DT
INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER :: I,J,K
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP=>NULL(),UU=>NULL(),VV=>NULL(),WW=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
REAL(EB) :: NU_EDDY,DELTA,A_IJ(3,3),DUDX,DUDY,DUDZ,DVDX,DVDY,DVDZ,DWDX,DWDY,DWDZ

REAL(EB) :: NVEC(IAXIS:KAXIS), TVEC1(IAXIS:KAXIS), TVEC2(IAXIS:KAXIS), VEL_WALL(IAXIS:KAXIS), VEL_CELL(IAXIS:KAXIS), &
            DN, RHO_WALL, MU_WALL, SLIP_FACTOR, TT(IAXIS:KAXIS), SS(IAXIS:KAXIS), &
            U_NORM, U_ORTH, U_STRM, U_CELL, V_CELL, W_CELL, U_RELA(IAXIS:KAXIS), TNOW
INTEGER  :: ICF,IND1,IND2
TYPE(CFACE_TYPE), POINTER :: CFA
TYPE(ONE_D_M_AND_E_XFER_TYPE), POINTER :: ONE_D
TYPE(SURFACE_TYPE), POINTER :: SF

TNOW = CURRENT_TIME()

IF (PREDICTOR) THEN
   RHOP => RHO
   UU   => U
   VV   => V
   WW   => W
   ZZP  => ZZ
ELSE
   RHOP => RHOS
   UU   => US
   VV   => VS
   WW   => WS
   ZZP  => ZZS
ENDIF

! No need to compute WALE model turbulent viscosity on cut-cell region.
LES_IF : IF (SIM_MODE/=DNS_MODE) THEN
   ! Define velocities on gas cut-faces underlaying Cartesian faces.
   IF(.NOT.CC_STRESS_METHOD) THEN
      T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
      IF (TIME_CC_IBM) &
         T_CC_USED(CCREGION_COMPUTE_VISCOSITY_TIME_INDEX) = T_CC_USED(CCREGION_COMPUTE_VISCOSITY_TIME_INDEX) + CURRENT_TIME() - TNOW
      CALL CCIBM_INTERP_FACE_VEL(DT,NM,.TRUE.) ! The flag is to test without interpolation to Cartesian faces,
                                               ! This is because we want to dispose of cartesian face
                                               ! interpolations.
      TNOW = CURRENT_TIME()
   ENDIF

   ! WALE model on cells belonging to cut-cell region:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
             IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
             IF(CCVAR(I,J,K,IBM_CGSC)==IBM_SOLID) THEN; MU(I,J,K) = MU_DNS(I,J,K); CYCLE; ENDIF
             IF(CCVAR(I,J,K,IBM_IDCF)<1) CYCLE ! Cycle everything except cut-cells with boundary CFACEs.

             DELTA = LES_FILTER_WIDTH_FUNCTION(DX(I),DY(J),DZ(K))
             ! compute velocity gradient tensor
             DUDX = RDX(I)*(UU(I,J,K)-UU(I-1,J,K))
             DVDY = RDY(J)*(VV(I,J,K)-VV(I,J-1,K))
             DWDZ = RDZ(K)*(WW(I,J,K)-WW(I,J,K-1))
             DUDY = 0.25_EB*RDY(J)*(UU(I,J+1,K)-UU(I,J-1,K)+UU(I-1,J+1,K)-UU(I-1,J-1,K))
             DUDZ = 0.25_EB*RDZ(K)*(UU(I,J,K+1)-UU(I,J,K-1)+UU(I-1,J,K+1)-UU(I-1,J,K-1))
             DVDX = 0.25_EB*RDX(I)*(VV(I+1,J,K)-VV(I-1,J,K)+VV(I+1,J-1,K)-VV(I-1,J-1,K))
             DVDZ = 0.25_EB*RDZ(K)*(VV(I,J,K+1)-VV(I,J,K-1)+VV(I,J-1,K+1)-VV(I,J-1,K-1))
             DWDX = 0.25_EB*RDX(I)*(WW(I+1,J,K)-WW(I-1,J,K)+WW(I+1,J,K-1)-WW(I-1,J,K-1))
             DWDY = 0.25_EB*RDY(J)*(WW(I,J+1,K)-WW(I,J-1,K)+WW(I,J+1,K-1)-WW(I,J-1,K-1))
             A_IJ(1,1)=DUDX; A_IJ(1,2)=DUDY; A_IJ(1,3)=DUDZ
             A_IJ(2,1)=DVDX; A_IJ(2,2)=DVDY; A_IJ(2,3)=DVDZ
             A_IJ(3,1)=DWDX; A_IJ(3,2)=DWDY; A_IJ(3,3)=DWDZ

             CALL WALE_VISCOSITY(NU_EDDY,A_IJ,DELTA)

             MU(I,J,K) = MU_DNS(I,J,K) + RHOP(I,J,K)*NU_EDDY

         ENDDO
      ENDDO
   ENDDO

   IF(.NOT.CC_STRESS_METHOD) THEN
      T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
      IF (TIME_CC_IBM) &
         T_CC_USED(CCREGION_COMPUTE_VISCOSITY_TIME_INDEX) = T_CC_USED(CCREGION_COMPUTE_VISCOSITY_TIME_INDEX) + CURRENT_TIME() - TNOW
      CALL CCIBM_INTERP_FACE_VEL(DT,NM,.FALSE.)
      TNOW = CURRENT_TIME()
   ENDIF
ENDIF LES_IF

! Now compute U_TAU and Y_PLUS on CFACES:
DO ICF=1,N_CFACE_CELLS

   CFA => CFACE(ICF)
   ONE_D => CFA%ONE_D
   SF => SURFACE(CFA%SURF_INDEX)

   ! Surface Velocity:
   NVEC = CFA%NVEC

   ! right now VEL_T not defined for CFACEs
   TVEC1=(/ 0._EB,0._EB,0._EB/)
   TVEC2=(/ 0._EB,0._EB,0._EB/)
   ! velocity vector of the surface
   VEL_WALL = -ONE_D%U_NORMAL*NVEC + SF%VEL_T(1)*TVEC1 + SF%VEL_T(2)*TVEC2

   ! find cut-cell adjacent to CFACE
   IND1 = CFA%CUT_FACE_IND1
   IND2 = CFA%CUT_FACE_IND2
   CALL GET_UVWGAS_CFACE(U_CELL,V_CELL,W_CELL,IND1,IND2)
   ! velocity vector in the centroid of the gas (cut) cell
   VEL_CELL = (/U_CELL,V_CELL,W_CELL/) ! (/1._EB,0._EB,0._EB/) ! test

   CALL GET_MUDNS_CFACE(MU_WALL,IND1,IND2)

   ! Gives local velocity components U_STRM , U_ORTH , U_NORM
   ! in terms of unit vectors SS,TT,NN:
   U_RELA(IAXIS:KAXIS) = VEL_CELL(IAXIS:KAXIS)-VEL_WALL(IAXIS:KAXIS)
   CALL GET_LOCAL_VELOCITY(U_RELA,NVEC,TT,SS,U_NORM,U_ORTH,U_STRM)

   DN  = 1._EB/ONE_D%RDN
   RHO_WALL = ONE_D%RHO_F

   CALL WALL_MODEL(SLIP_FACTOR,ONE_D%U_TAU,ONE_D%Y_PLUS,MU_WALL/RHO_WALL,SF%ROUGHNESS,0.5_EB*DN,U_STRM)

ENDDO

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) &
   T_CC_USED(CCREGION_COMPUTE_VISCOSITY_TIME_INDEX) = T_CC_USED(CCREGION_COMPUTE_VISCOSITY_TIME_INDEX) + CURRENT_TIME() - TNOW


RETURN
END SUBROUTINE CCREGION_COMPUTE_VISCOSITY


! -------------------------------- ADD_Q_DOT_CUTCELLS ------------------------------

SUBROUTINE ADD_Q_DOT_CUTCELLS(NM,QCOMB,QRAD,QPRES,SP_ENTH)

! This routine assumes POINT_TO_MESH(NM) has already been called for mesh NM.

USE PHYSICAL_FUNCTIONS, ONLY : GET_SENSIBLE_ENTHALPY

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(INOUT) :: QCOMB,QRAD,QPRES,SP_ENTH

! Local Variables:
INTEGER :: ICC, JCC, I, J, K
REAL(EB):: VC,ZZ_GET(1:N_TRACKED_SPECIES),H_S

DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
   I = CUT_CELL(ICC)%IJK(IAXIS)
   J = CUT_CELL(ICC)%IJK(JAXIS)
   K = CUT_CELL(ICC)%IJK(KAXIS)
   VC = DX(I)*DY(J)*DZ(K)
   QPRES = QPRES + 0.5_EB*(D_PBAR_DT_S(PRESSURE_ZONE(I,J,K))+D_PBAR_DT(PRESSURE_ZONE(I,J,K)))*VC
   DO JCC=1,CUT_CELL(ICC)%NCELL
    QCOMB = QCOMB + CUT_CELL(ICC)%Q(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
    QRAD  = QRAD  + CUT_CELL(ICC)%QR(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
    ZZ_GET(1:N_TRACKED_SPECIES) = CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC)
    CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,CUT_CELL(ICC)%TMP(JCC))
    SP_ENTH = SP_ENTH + CUT_CELL(ICC)%RHO(JCC)*H_S*CUT_CELL(ICC)%VOLUME(JCC)
   ENDDO
ENDDO


RETURN
END SUBROUTINE ADD_Q_DOT_CUTCELLS



! -------------------------- CFACE_PREDICT_NORMAL_VELOCITY -------------------------

SUBROUTINE CFACE_PREDICT_NORMAL_VELOCITY(T,DT)


USE MATH_FUNCTIONS, ONLY : EVALUATE_RAMP

REAL(EB), INTENT(IN) :: T, DT

! Local variables:
INTEGER :: ICF, KK
TYPE(CFACE_TYPE), POINTER :: CFA=>NULL()
TYPE(SURFACE_TYPE), POINTER :: SF
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P
REAL(EB) :: DELTA_P, TSI, TIME_RAMP_FACTOR, PRES_RAMP_FACTOR, VEL_INTO_BOD0

SELECT CASE(PREDICTOR)
   CASE(.TRUE.)
      PBAR_P => PBAR_S
   CASE(.FALSE.)
      PBAR_P => PBAR
END SELECT

PREDICT_NORMALS: IF (PREDICTOR) THEN

   CFACE_LOOP: DO ICF=1,N_CFACE_CELLS

      CFA => CFACE(ICF)

      WALL_CELL_TYPE: SELECT CASE (CFA%BOUNDARY_TYPE)

         CASE (NULL_BOUNDARY)

            CFA%ONE_D%U_NORMAL_S = 0._EB

         CASE (SOLID_BOUNDARY)

            SF => SURFACE(CFA%SURF_INDEX)

            IF (SF%SPECIES_BC_INDEX==SPECIFIED_MASS_FLUX .OR. &
                CFA%ONE_D%NODE_INDEX > 0                 .OR. &
                ANY(SF%LEAK_PATH>0))                          &
                CYCLE CFACE_LOOP

            IF (ABS(CFA%ONE_D%T_IGN-T_BEGIN) < SPACING(CFA%ONE_D%T_IGN) .AND. SF%RAMP_INDEX(TIME_VELO)>=1) THEN
               TSI = T + DT
            ELSE
               TSI = T + DT - CFA%ONE_D%T_IGN
               IF (TSI<0._EB) THEN
                  CFA%ONE_D%U_NORMAL_S = 0._EB
                  CYCLE CFACE_LOOP
               ENDIF
            ENDIF
            TIME_RAMP_FACTOR = EVALUATE_RAMP(TSI,SF%TAU(TIME_VELO),SF%RAMP_INDEX(TIME_VELO))
            KK               = CFA%ONE_D%KK
            DELTA_P          = PBAR_P(KK,SF%DUCT_PATH(1)) - PBAR_P(KK,SF%DUCT_PATH(2))
            PRES_RAMP_FACTOR = SIGN(1._EB,SF%MAX_PRESSURE-DELTA_P)*SQRT(ABS((DELTA_P-SF%MAX_PRESSURE)/SF%MAX_PRESSURE))

            VEL_INTO_BOD0    =-(CFA%NVEC(IAXIS)*U0 + CFA%NVEC(JAXIS)*V0 + CFA%NVEC(KAXIS)*W0)

            CFA%ONE_D%U_NORMAL_S    = VEL_INTO_BOD0 + TIME_RAMP_FACTOR*(CFA%ONE_D%U_NORMAL_0-VEL_INTO_BOD0)

            ! Special Cases
            ! NEUMANN_IF: IF (SF%SPECIFIED_NORMAL_GRADIENT) THEN
            ! TO DO, following PREDICT_NORMAL_VELOCITY.

            IF (ABS(SURFACE(CFA%SURF_INDEX)%MASS_FLUX_TOTAL)>=TWO_EPSILON_EB) CFA%ONE_D%U_NORMAL_S = &
                                                                              CFA%ONE_D%U_NORMAL_S*RHOA/CFA%ONE_D%RHO_F

            ! VENT_IF: IF (WC%VENT_INDEX>0) THEN
            ! TO DO, following PREDICT_NORMAL_VELOCITY.

      END SELECT WALL_CELL_TYPE

   ENDDO CFACE_LOOP

ELSE PREDICT_NORMALS

   ! In the CORRECTOR step, the normal component of velocity, U_NORMAL, is the same as the predicted value, U_NORMAL_S.
   ! However, for species mass fluxes and HVAC, U_NORMAL is computed elsewhere (wall.f90).

   CFACE_LOOPC: DO ICF=1,N_CFACE_CELLS
      CFA => CFACE(ICF)
      IF (CFA%BOUNDARY_TYPE==SOLID_BOUNDARY) THEN
         SF => SURFACE(CFA%SURF_INDEX)
         IF (SF%SPECIES_BC_INDEX==SPECIFIED_MASS_FLUX .OR. &
             CFA%ONE_D%NODE_INDEX > 0                 .OR. &
             ANY(SF%LEAK_PATH>0) ) CYCLE
      ENDIF
      CFA%ONE_D%U_NORMAL = CFA%ONE_D%U_NORMAL_S
   ENDDO CFACE_LOOPC

ENDIF PREDICT_NORMALS

RETURN

END SUBROUTINE CFACE_PREDICT_NORMAL_VELOCITY


! ---------------------------- ROTATED_CUBE_VELOCITY_FLUX --------------------------

SUBROUTINE ROTATED_CUBE_VELOCITY_FLUX(NM,TLEVEL)

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN):: TLEVEL

! Local Variables:
REAL(EB) :: XGLOB(2,1), XLOC(2,1), FGLOB(2,1), FLOC(2,1), X_I, Y_J, NU
INTEGER  :: I,J,K
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP=>NULL()
REAL(EB) :: SIN_T, COS_T, COS_KX, SIN_KX, COS_KY, SIN_KY

CALL POINT_TO_MESH(NM)

IF (PREDICTOR) THEN
   RHOP => RHO
ELSE
   RHOP => RHOS
ENDIF

ROTANG = 0._EB
IF(PERIODIC_TEST==21) THEN
   ROTANG = 0._EB ! No rotation.
ELSEIF(PERIODIC_TEST==22) THEN
   ROTANG = ATAN(1._EB/2._EB) ! ~27 Degrees.
ELSEIF(PERIODIC_TEST==23) THEN
   ROTANG = ATAN(1._EB)       ! 45 degrees.
ELSE
   RETURN
ENDIF
ROTMAT(1,1) = COS(ROTANG); ROTMAT(1,2) = -SIN(ROTANG);
ROTMAT(2,1) = SIN(ROTANG); ROTMAT(2,2) =  COS(ROTANG);
TROTMAT = TRANSPOSE(ROTMAT)

COS_T = COS(TLEVEL)
SIN_T = SIN(TLEVEL)

! X Force:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         IF (CC_IBM) THEN
            IF (.NOT.CC_STRESS_METHOD .AND. FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_GASPHASE) CYCLE ! Case of regular IBM.
            IF (     CC_STRESS_METHOD .AND. FCVAR(I,J,K,IBM_FGSC,IAXIS) == IBM_SOLID) CYCLE    ! Stress method.
         ENDIF
         ! Kinematic Viscosity:
         NU = 0.5_EB*(MU(I,J,K)/RHOP(I,J,K) + MU(I+1,J,K)/RHOP(I+1,J,K))

         ! Global position:
         XGLOB(1:2,1) = (/ X(I), ZC(K) /)

         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)

         X_I = XLOC(1,1); Y_J = XLOC(2,1)

         COS_KX = COS(NWAVE*X_I)
         SIN_KX = SIN(NWAVE*X_I)

         COS_KY = COS(NWAVE*Y_J)
         SIN_KY = SIN(NWAVE*Y_J)

         FLOC(1,1)=2._EB*COS_KY*SIN_KX**2._EB*SIN_KY*COS_T - &
         4._EB*NWAVE*SIN_KY*SIN_T*(COS_KX*SIN_KX**3._EB*SIN_KY*SIN_T + &
         NWAVE*NU*COS_KX**2._EB*COS_KY - 3._EB*NWAVE*NU*COS_KY*SIN_KX**2._EB) + &
         NWAVE*COS_KX*SIN_KX*SIN_T*(2._EB*COS_KY**2._EB + 1._EB);


         FLOC(2,1)= NWAVE*COS_KY*SIN_KY*SIN_T*(2._EB*COS_KX**2._EB + 1._EB) - &
         2._EB*COS_KX*SIN_KX*SIN_KY**2._EB*COS_T - &
         4._EB*NWAVE*SIN_KX*SIN_T*(COS_KY*SIN_KX*SIN_KY**3._EB*SIN_T - &
         NWAVE*NU*COS_KX*COS_KY**2._EB + 3._EB*NWAVE*NU*COS_KX*SIN_KY**2._EB);

         FGLOB        = MATMUL(ROTMAT, FLOC )

         FVX(I,J,K)   = FVX(I,J,K) + 0.5_EB*(RHOP(I,J,K)+RHOP(I+1,J,K))*FGLOB(IAXIS,1)

      ENDDO
   ENDDO
ENDDO


! Z Force:
DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (CC_IBM) THEN
            IF (.NOT.CC_STRESS_METHOD .AND. FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_GASPHASE) CYCLE ! Case of regular IBM.
            IF (     CC_STRESS_METHOD .AND. FCVAR(I,J,K,IBM_FGSC,KAXIS) == IBM_SOLID) CYCLE    ! Stress method.
         ENDIF
         ! Kinematic Viscosity:
         NU = 0.5_EB*(MU(I,J,K)/RHOP(I,J,K) + MU(I,J,K+1)/RHOP(I,J,K+1))

         ! Global position:
         XGLOB(1:2,1) = (/ XC(I), Z(K) /)

         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)

         X_I = XLOC(1,1); Y_J = XLOC(2,1)

         COS_KX = COS(NWAVE*X_I)
         SIN_KX = SIN(NWAVE*X_I)

         COS_KY = COS(NWAVE*Y_J)
         SIN_KY = SIN(NWAVE*Y_J)

         FLOC(1,1)=2._EB*COS_KY*SIN_KX**2._EB*SIN_KY*COS_T - &
         4._EB*NWAVE*SIN_KY*SIN_T*(COS_KX*SIN_KX**3._EB*SIN_KY*SIN_T + &
         NWAVE*NU*COS_KX**2._EB*COS_KY - 3._EB*NWAVE*NU*COS_KY*SIN_KX**2._EB) + &
         NWAVE*COS_KX*SIN_KX*SIN_T*(2._EB*COS_KY**2._EB + 1._EB);


         FLOC(2,1)= NWAVE*COS_KY*SIN_KY*SIN_T*(2._EB*COS_KX**2._EB + 1._EB) - &
         2._EB*COS_KX*SIN_KX*SIN_KY**2._EB*COS_T - &
         4._EB*NWAVE*SIN_KX*SIN_T*(COS_KY*SIN_KX*SIN_KY**3._EB*SIN_T - &
         NWAVE*NU*COS_KX*COS_KY**2._EB + 3._EB*NWAVE*NU*COS_KX*SIN_KY**2._EB);

         FGLOB        = MATMUL(ROTMAT, FLOC )

         FVZ(I,J,K)   = FVZ(I,J,K) + 0.5_EB*(RHOP(I,J,K)+RHOP(I,J,K+1))*FGLOB(JAXIS,1)

      ENDDO
   ENDDO
ENDDO


RETURN
END SUBROUTINE ROTATED_CUBE_VELOCITY_FLUX

! ------------------------------ ROTATED_CUBE_ANN_SOLN ----------------------------

SUBROUTINE ROTATED_CUBE_ANN_SOLN(NM,TLEVEL)

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN):: TLEVEL

! Local Variables:
REAL(EB) :: XGLOB(2,1), XLOC(2,1), UGLOB(2,1), ULOC(2,1), VEL_CF
INTEGER :: I,J,K,NFACE,X1AXIS,ICF,ICF2,ICC,JCC,NCELL

ROTANG = 0._EB
IF(PERIODIC_TEST==21) THEN
   ROTANG = 0._EB ! No rotation.
ELSEIF(PERIODIC_TEST==22) THEN
   ROTANG = ATAN(1._EB/2._EB) ! ~27 Degrees.
ELSEIF(PERIODIC_TEST==23) THEN
   ROTANG = ATAN(1._EB)       ! 45 degrees.
ELSE
   RETURN
ENDIF
ROTMAT(1,1) = COS(ROTANG); ROTMAT(1,2) = -SIN(ROTANG);
ROTMAT(2,1) = SIN(ROTANG); ROTMAT(2,2) =  COS(ROTANG);
TROTMAT = TRANSPOSE(ROTMAT)

CALL POINT_TO_MESH(NM)


! X Velocities:
DO K=0,KBP1
   DO J=0,JBP1
      DO I=0,IBAR
         ! Global position:
         XGLOB(1:2,1) = (/ X(I), ZC(K) /)

         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)

         ! Velocity field in local axes:
         ULOC(IAXIS,1)= -SIN(NWAVE*XLOC(IAXIS,1))**2._EB * SIN(2._EB*NWAVE*XLOC(JAXIS,1))
         ULOC(JAXIS,1)=  SIN(2._EB*NWAVE*XLOC(IAXIS,1))  * SIN(NWAVE*XLOC(JAXIS,1))**2._EB

         ! Velocity field in global axes:
         UGLOB        = MATMUL(ROTMAT,ULOC)
         U(I,J,K)     = SIN(TLEVEL) * UGLOB(IAXIS,1)

      ENDDO
   ENDDO
ENDDO

! Y Velocities:
V(:,:,:)=0._EB

! Z Velocities:
DO K=0,KBAR
   DO J=0,JBP1
      DO I=0,IBP1
         ! Global position:
         XGLOB(1:2,1) = (/ XC(I), Z(K) /)

         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)

         ! Velocity field in local axes:
         ULOC(IAXIS,1)= -SIN(NWAVE*XLOC(IAXIS,1))**2._EB * SIN(2._EB*NWAVE*XLOC(JAXIS,1))
         ULOC(JAXIS,1)=  SIN(2._EB*NWAVE*XLOC(IAXIS,1))  * SIN(NWAVE*XLOC(JAXIS,1))**2._EB

         ! Velocity field in global axes:
         UGLOB        = MATMUL(ROTMAT,ULOC)
         W(I,J,K)     = SIN(TLEVEL) * UGLOB(JAXIS,1)

      ENDDO
   ENDDO
ENDDO

! Now GASPHASE cut-faces:
IF (CC_IBM) THEN
   CUTFACE_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      NFACE  = CUT_FACE(ICF)%NFACE
      IF (CUT_FACE(ICF)%STATUS == IBM_GASPHASE) THEN
         I      = CUT_FACE(ICF)%IJK(IAXIS)
         J      = CUT_FACE(ICF)%IJK(JAXIS)
         K      = CUT_FACE(ICF)%IJK(KAXIS)
         X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
         DO ICF2=1,NFACE
            ! Global position:
            XGLOB(1:2,1) = (/ CUT_FACE(ICF)%XYZCEN(IAXIS,ICF2), CUT_FACE(ICF)%XYZCEN(KAXIS,ICF2) /)

            ! Local position:
            XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
            XLOC         = MATMUL(TROTMAT, XGLOB )
            XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)

            ! Velocity field in local axes:
            ULOC(IAXIS,1)= -SIN(NWAVE*XLOC(IAXIS,1))**2._EB * SIN(2._EB*NWAVE*XLOC(JAXIS,1))
            ULOC(JAXIS,1)=  SIN(2._EB*NWAVE*XLOC(IAXIS,1))  * SIN(NWAVE*XLOC(JAXIS,1))**2._EB

            ! Velocity field in global axes:
            UGLOB        = MATMUL(ROTMAT,ULOC)
            SELECT CASE(X1AXIS)
            CASE(IAXIS)
               VEL_CF = SIN(TLEVEL) * UGLOB(IAXIS,1)
            CASE(JAXIS)
               VEL_CF = 0._EB
            CASE(KAXIS)
               VEL_CF = SIN(TLEVEL) * UGLOB(JAXIS,1)
            END SELECT

            CUT_FACE(ICF)%VEL(ICF2)  = VEL_CF
            CUT_FACE(ICF)%VELS(ICF2) = VEL_CF

         ENDDO

      ELSE ! IBM_INBOUNDARY

         VEL_CF = 0._EB
         CUT_FACE(ICF)%VEL(1:NFACE)  = VEL_CF
         CUT_FACE(ICF)%VELS(1:NFACE) = VEL_CF

      ENDIF
   ENDDO CUTFACE_LOOP
ENDIF

! Fields for scalars:
! Regular cells:
DO K=0,KBP1
   DO J=0,JBP1
      DO I=0,IBP1
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
         ! Global position:
         XGLOB(1:2,1) = (/ XC(I), ZC(K) /)

         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)

         ZZ(I,J,K,N_SPEC_NEUMN) = AMP_Z/3._EB*SIN(TLEVEL)*(1._EB-COS(2._EB*NWAVE*(XLOC(IAXIS,1)-GAM))) * &
                                                          (1._EB-COS(2._EB*NWAVE*(XLOC(JAXIS,1)-GAM)))   &
                                                          -AMP_Z/3._EB*SIN(TLEVEL) + MEAN_Z
         ZZ(I,J,K,N_SPEC_BACKG) = 1._EB - ZZ(I,J,K,N_SPEC_NEUMN)

      ENDDO
   ENDDO
ENDDO

! Cut cells:
IF (CC_IBM) THEN
   CUTCELL_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      NCELL  = CUT_CELL(ICC)%NCELL
      DO JCC=1,NCELL
         ! Global position:
         XGLOB(1:2,1) = (/ CUT_CELL(ICC)%XYZCEN(IAXIS,JCC), CUT_CELL(ICC)%XYZCEN(KAXIS,JCC) /)

         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)

         CUT_CELL(ICC)%ZZ(N_SPEC_NEUMN,JCC) = AMP_Z/3._EB*SIN(TLEVEL)*(1._EB-COS(2._EB*NWAVE*(XLOC(IAXIS,1)-GAM))) * &
                                                                      (1._EB-COS(2._EB*NWAVE*(XLOC(JAXIS,1)-GAM)))   &
                                                                      -AMP_Z/3._EB*SIN(TLEVEL) + MEAN_Z
         CUT_CELL(ICC)%ZZ(N_SPEC_BACKG,JCC) = 1._EB - CUT_CELL(ICC)%ZZ(N_SPEC_NEUMN,JCC)
      ENDDO
   ENDDO CUTCELL_LOOP
ENDIF


RETURN

END SUBROUTINE ROTATED_CUBE_ANN_SOLN

! ------------------------------ ROTATED_CUBE_RHS_ZZ -----------------------------------

SUBROUTINE ROTATED_CUBE_RHS_ZZ(TLEVEL,DT,NM)

USE MATH_FUNCTIONS, ONLY: INTERPOLATE1D_UNIFORM

REAL(EB), INTENT(IN) :: TLEVEL,DT
INTEGER, INTENT(IN)  :: NM

! Local Variables:
INTEGER :: I, J ,K
REAL(EB), POINTER, DIMENSION(:,:,:)   :: RHOP
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP
REAL(EB) :: D_Z_N(0:5000),XLOC(2,1),XGLOB(2,1),Q_ZN,D_Z_TEMP,RHO_IJK,DTFC
REAL(EB) :: SIN_T, COS_T

ROTANG = 0._EB
IF(PERIODIC_TEST==21) THEN
   ROTANG = 0._EB ! No rotation.
ELSEIF(PERIODIC_TEST==22) THEN
   ROTANG = ATAN(1._EB/2._EB) ! ~27 Degrees.
ELSEIF(PERIODIC_TEST==23) THEN
   ROTANG = ATAN(1._EB)       ! 45 degrees.
ELSE
   RETURN
ENDIF
ROTMAT(1,1) = COS(ROTANG); ROTMAT(1,2) = -SIN(ROTANG);
ROTMAT(2,1) = SIN(ROTANG); ROTMAT(2,2) =  COS(ROTANG);
TROTMAT = TRANSPOSE(ROTMAT)

SIN_T    = SIN(TLEVEL)
COS_T    = COS(TLEVEL)

CALL POINT_TO_MESH(NM)

IF (PREDICTOR) THEN
   RHOP => RHO
   ZZP  => ZZS
   DTFC = 1._EB
ELSE
   RHOP => RHOS
   ZZP  => ZZ
   DTFC = 0.5_EB
ENDIF

D_Z_N=D_Z(:,N_SPEC_NEUMN)

! Add Q_Z on regular cells:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
         IF (CC_IBM) THEN
            IF(CCVAR(I,J,K,IBM_CGSC)/=IBM_GASPHASE) CYCLE
            IF(CCVAR(I,J,K,IBM_UNKZ)>0) CYCLE
         ENDIF
         ! Global position:
         XGLOB(1:2,1) = (/ XC(I), ZC(K) /)
         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)
         RHO_IJK = RHOP(I,J,K)
         CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,TMP(I,J,K),D_Z_TEMP)
         CALL ROTATED_CUBE_NEUMN_FZ(SIN_T,COS_T,RHO_IJK,D_Z_TEMP,XLOC,Q_ZN)

         ! Update species:
         ZZP(I,J,K,N_SPEC_NEUMN) = ZZP(I,J,K,N_SPEC_NEUMN) + DTFC*DT*Q_ZN
         ZZP(I,J,K,N_SPEC_BACKG) = ZZP(I,J,K,N_SPEC_BACKG) - DTFC*DT*Q_ZN
      ENDDO
   ENDDO
ENDDO


RETURN
END SUBROUTINE ROTATED_CUBE_RHS_ZZ

! ------------------------- CCREGION_ROTATED_CUBE_RHS_ZZ -------------------------------

SUBROUTINE CCREGION_ROTATED_CUBE_RHS_ZZ(TLEVEL,N)

USE MATH_FUNCTIONS, ONLY: INTERPOLATE1D_UNIFORM

REAL(EB), INTENT(IN) :: TLEVEL
INTEGER, INTENT(IN)  :: N

! Local Variables:
INTEGER :: NM, I, J ,K, IROW, ICC, JCC
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP
REAL(EB) :: PREDFCT,D_Z_N(0:5000),XLOC(2,1),XGLOB(2,1),Q_Z,D_Z_TEMP,RHO_IJK,FCT
REAL(EB) :: SIN_T, COS_T

ROTANG = 0._EB
IF(PERIODIC_TEST==21) THEN
   ROTANG = 0._EB ! No rotation.
ELSEIF(PERIODIC_TEST==22) THEN
   ROTANG = ATAN(1._EB/2._EB) ! ~27 Degrees.
ELSEIF(PERIODIC_TEST==23) THEN
   ROTANG = ATAN(1._EB)       ! 45 degrees.
ELSE
   RETURN
ENDIF
ROTMAT(1,1) = COS(ROTANG); ROTMAT(1,2) = -SIN(ROTANG);
ROTMAT(2,1) = SIN(ROTANG); ROTMAT(2,2) =  COS(ROTANG);
TROTMAT = TRANSPOSE(ROTMAT)

SIN_T    = SIN(TLEVEL)
COS_T    = COS(TLEVEL)

MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN
      PREDFCT=1._EB
      RHOP => RHO
   ELSE
      PREDFCT=0._EB
      RHOP => RHOS
   ENDIF

   D_Z_N = D_Z(:,N)

   ! First add Q_Z on regular cells to source F_Z:
   IF (N==N_SPEC_BACKG) THEN
      FCT=-1._EB
   ELSEIF (N==N_SPEC_NEUMN) THEN
      FCT=1._EB
   ENDIF

   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF(CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            IROW = CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
            ! Global position:
            XGLOB(1:2,1) = (/ XC(I), ZC(K) /)
            ! Local position:
            XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
            XLOC         = MATMUL(TROTMAT, XGLOB )
            XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)
            CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,TMP(I,J,K),D_Z_TEMP)
            RHO_IJK = RHOP(I,J,K)
            CALL ROTATED_CUBE_NEUMN_FZ(SIN_T,COS_T,RHO_IJK,D_Z_TEMP,XLOC,Q_Z)
            F_Z(IROW) = F_Z(IROW) - FCT*Q_Z*DX(I)*DY(J)*DZ(K)
         ENDDO
      ENDDO
   ENDDO
   ! Then add Cut-cell contributions to F_Z:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         IROW = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
         ! Global position:
         XGLOB(1:2,1) = (/ CUT_CELL(ICC)%XYZCEN(IAXIS,JCC), CUT_CELL(ICC)%XYZCEN(KAXIS,JCC) /)
         ! Local position:
         XGLOB(1:2,1) = XGLOB(1:2,1) - DISPL
         XLOC         = MATMUL(TROTMAT, XGLOB )
         XLOC( 1:2,1) = XLOC( 1:2,1) - DISPXY(1:2,1)
         CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,CUT_CELL(ICC)%TMP(JCC),D_Z_TEMP)
         RHO_IJK = (1._EB - PREDFCT)*CUT_CELL(ICC)%RHOS(JCC) + PREDFCT*CUT_CELL(ICC)%RHO(JCC)
         CALL ROTATED_CUBE_NEUMN_FZ(SIN_T,COS_T,RHO_IJK,D_Z_TEMP,XLOC,Q_Z)
         F_Z(IROW) = F_Z(IROW) - FCT*Q_Z*CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO
   ENDDO

ENDDO MESH_LOOP


RETURN
END SUBROUTINE CCREGION_ROTATED_CUBE_RHS_ZZ

! ---------------------------------- ROTATED_CUBE_NEUMN_FZ ---------------------------------

SUBROUTINE ROTATED_CUBE_NEUMN_FZ(SIN_T,COS_T,RHO_IJK,D_Z_TEMP,XLOC,Q_Z)

REAL(EB), INTENT(IN) :: SIN_T,COS_T, RHO_IJK, D_Z_TEMP, XLOC(2,1)
REAL(EB), INTENT(OUT):: Q_Z

! Local Variables:
REAL(EB) :: COS_2KGX, COS_2KGZ, SIN_2KGX, SIN_2KGZ
REAL(EB) :: COS_KX, COS_KZ, SIN_KX, SIN_KZ
REAL(EB) :: SIN_2KX, SIN_2KZ

Q_Z=0._EB

COS_2KGX = COS(2._EB*NWAVE*(GAM - XLOC(IAXIS,1)))
COS_2KGZ = COS(2._EB*NWAVE*(GAM - XLOC(JAXIS,1)))

SIN_2KGX = SIN(2._EB*NWAVE*(GAM - XLOC(IAXIS,1)))
SIN_2KGZ = SIN(2._EB*NWAVE*(GAM - XLOC(JAXIS,1)))

COS_KX   = COS(NWAVE*XLOC(IAXIS,1))
COS_KZ   = COS(NWAVE*XLOC(JAXIS,1))
SIN_KX   = SIN(NWAVE*XLOC(IAXIS,1))
SIN_KZ   = SIN(NWAVE*XLOC(JAXIS,1))

SIN_2KX  = SIN(2._EB*NWAVE*XLOC(IAXIS,1))
SIN_2KZ  = SIN(2._EB*NWAVE*XLOC(JAXIS,1))

Q_Z = (4._EB*AMP_Z*D_Z_TEMP*NWAVE**2*RHO_IJK*COS_2KGX*SIN_T*(COS_2KGZ - 1._EB))/3._EB - &
       RHO_IJK*((AMP_Z*COS_T)/3._EB - (AMP_Z*COS_T*(COS_2KGX - 1._EB)*(COS_2KGZ - 1._EB))/3._EB) + &
      (4._EB*AMP_Z*D_Z_TEMP*NWAVE**2*RHO_IJK*COS_2KGZ*SIN_T*(COS_2KGX - 1._EB))/3._EB - &
       2._EB*NWAVE*RHO_IJK*COS_KX*SIN_KX*SIN_2KZ*SIN_T*(MEAN_Z - &
      (AMP_Z*SIN_T)/3._EB + (AMP_Z*SIN_T*(COS_2KGX - 1._EB)*(COS_2KGZ - 1._EB))/3._EB) + &
       2._EB*NWAVE*RHO_IJK*COS_KZ*SIN_2KX*SIN_KZ*SIN_T*(MEAN_Z - (AMP_Z*SIN_T)/3._EB + &
      (AMP_Z*SIN_T*(COS_2KGX - 1._EB)*(COS_2KGZ - 1._EB))/3._EB) + &
      (2._EB*AMP_Z*NWAVE*RHO_IJK*SIN_2KX*SIN_KZ**2*SIN_2KGZ*SIN_T**2*(COS_2KGX - 1._EB))/3._EB - &
      (2._EB*AMP_Z*NWAVE*RHO_IJK*SIN_KX**2*SIN_2KZ*SIN_2KGX*SIN_T**2*(COS_2KGZ - 1._EB))/3._EB


RETURN
END SUBROUTINE ROTATED_CUBE_NEUMN_FZ


! --------------------------------- GET_SHUNN3_QZ --------------------------------

SUBROUTINE GET_SHUNN3_QZ(T,N)

USE MANUFACTURED_SOLUTIONS, ONLY: UF_MMS,WF_MMS,VD2D_MMS_Z_SRC

REAL(EB),INTENT(IN) :: T
INTEGER, INTENT(IN) :: N

! Local Variables:
INTEGER I,J,K,NM,IROW,ICC,JCC
REAL(EB) :: FCT,XHAT,ZHAT,Q_Z

FCT=REAL(2*(1-N)+1,EB)

! Mesh Loop:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! First add Q_Z on regular cells to source F_Z:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF(CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            IROW = CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
            ! divergence from EOS
            XHAT = XC(I) - UF_MMS*T
            ZHAT = ZC(K) - WF_MMS*T
            Q_Z = VD2D_MMS_Z_SRC(XHAT,ZHAT,T)
            F_Z(IROW) = F_Z(IROW) + FCT*Q_Z*DX(I)*DY(J)*DZ(K)
         ENDDO
      ENDDO
   ENDDO

   ! Then add Cut-cell contributions to F_Z:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         IROW = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
         ! divergence from EOS
         XHAT = CUT_CELL(ICC)%XYZCEN(IAXIS,JCC) - UF_MMS*T
         ZHAT = CUT_CELL(ICC)%XYZCEN(KAXIS,JCC) - WF_MMS*T
         Q_Z = VD2D_MMS_Z_SRC(XHAT,ZHAT,T)
         F_Z(IROW) = F_Z(IROW) + FCT*Q_Z*CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO
   ENDDO

ENDDO MESH_LOOP

RETURN
END SUBROUTINE GET_SHUNN3_QZ


! ---------------------------------- GET_MUDNS_CFACE --------------------------------

SUBROUTINE GET_MUDNS_CFACE(MU_WALL,IND1,IND2)

USE PHYSICAL_FUNCTIONS, ONLY : GET_VISCOSITY

REAL(EB), INTENT(OUT)::  MU_WALL
INTEGER, INTENT(IN) :: IND1,IND2

! Local Variables:
INTEGER :: VIND, EP, INT_NPE_LO, INT_NPE_HI, INPE, ICC, IIG, JJG, KKG
REAL(EB):: MU_DNS_EP, TMP_EP, ZZ_GET(1:N_TRACKED_SPECIES)

! Cell-centered variables:
VIND=0;  EP  =1
INT_NPE_LO  = CUT_FACE(IND1)%INT_NPE( LOW_IND,VIND,EP,IND2)
INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)
IF (INT_NPE_HI > 0) THEN
   MU_WALL=0._EB
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      ! Compute MU_DNS for INPE:
      ZZ_GET(1:N_TRACKED_SPECIES) = CUT_FACE(IND1)%INT_CVARS(INT_P_IND+1:INT_P_IND+N_TRACKED_SPECIES,INPE)
      TMP_EP = CUT_FACE(IND1)%INT_CVARS( INT_TMP_IND,INPE)
      CALL GET_VISCOSITY(ZZ_GET,MU_DNS_EP,TMP_EP)
      ! Add to MU_WALL:
      MU_WALL = MU_WALL + CUT_FACE(IND1)%INT_COEF(INPE)*MU_DNS_EP
   ENDDO
ELSE
   ! Underlying cell approximate value:
   ICC = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2)
   IIG = CUT_CELL(ICC)%IJK(1)
   JJG = CUT_CELL(ICC)%IJK(2)
   KKG = CUT_CELL(ICC)%IJK(3)
   MU_WALL = MU_DNS(IIG,JJG,KKG)
ENDIF

RETURN
END SUBROUTINE GET_MUDNS_CFACE

! ---------------------------------- GET_UVWGAS_CFACE --------------------------------

SUBROUTINE GET_UVWGAS_CFACE(U_CELL,V_CELL,W_CELL,IND1,IND2)

INTEGER, INTENT(IN) :: IND1,IND2
REAL(EB),INTENT(OUT):: U_CELL,V_CELL,W_CELL


! Local Variables:
INTEGER :: VIND, EP, INT_NPE_LO, INT_NPE_HI, INPE
REAL(EB):: VVEL(IAXIS:KAXIS)

EP =1
VVEL(IAXIS:KAXIS) = 0._EB
DO VIND=IAXIS,KAXIS
   INT_NPE_LO  = CUT_FACE(IND1)%INT_NPE( LOW_IND,VIND,EP,IND2)
   INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      VVEL(VIND) = VVEL(VIND) + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_FVARS(INT_VEL_IND,INPE)
   ENDDO
ENDDO

U_CELL = VVEL(IAXIS)
V_CELL = VVEL(JAXIS)
W_CELL = VVEL(KAXIS)

RETURN
END SUBROUTINE GET_UVWGAS_CFACE

! ----------------------------------- GET_PRES_CFACE ---------------------------------

SUBROUTINE GET_PRES_CFACE(PRESS,IND1,IND2,ONE_D)

INTEGER,  INTENT( IN) :: IND1, IND2
REAL(EB), INTENT(OUT) :: PRESS
TYPE(ONE_D_M_AND_E_XFER_TYPE), INTENT(IN), POINTER :: ONE_D

! Local Variables:
INTEGER :: VIND, EP, INT_NPE_LO, INT_NPE_HI, INPE, ICC, IIG, JJG, KKG
! REAL(EB):: VVEL(IAXIS:KAXIS), U_NORM

! Cell-centered variables:
VIND=0; EP  = 1
INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)
IF (INT_NPE_HI > 0) THEN
   ! ! First normal velocity:
   ! VVEL(IAXIS:KAXIS) = 0._EB
   ! DO VIND=IAXIS,KAXIS
   !    INT_NPE_LO  = CUT_FACE(IND1)%INT_NPE( LOW_IND,VIND,EP,IND2)
   !    INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)
   !    DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
   !       VVEL(VIND) = VVEL(VIND) + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_FVARS(INT_VEL_IND,INPE)
   !    ENDDO
   ! ENDDO
   ! U_NORM = DOT_PRODUCT(VVEL , CFACE(CUT_FACE(IND1)%CFACE_INDEX(IND2))%NVEC)

   ! Now Pressure:
   ! VIND=0;
   PRESS=0._EB
   INT_NPE_LO  = CUT_FACE(IND1)%INT_NPE( LOW_IND,VIND,EP,IND2)
   ! INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      PRESS = PRESS + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_CVARS( INT_P_IND,INPE)
   ENDDO
   ! PRESS = PRESS + ONE_D%RHO_F*U_NORM**2._EB
ELSE
   ! Underlying cell approximate value:
   ICC = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2)
   IIG = CUT_CELL(ICC)%IJK(1)
   JJG = CUT_CELL(ICC)%IJK(2)
   KKG = CUT_CELL(ICC)%IJK(3)
   PRESS=ONE_D%RHO_G*(H(IIG,JJG,KKG)-KRES(IIG,JJG,KKG))
ENDIF

RETURN
END SUBROUTINE GET_PRES_CFACE

! ----------------------------------- GET_PRES_CFACE_TEST ---------------------------------

SUBROUTINE GET_PRES_CFACE_TEST(PRESS,IND1,IND2,ONE_D)

INTEGER,  INTENT( IN) :: IND1, IND2
REAL(EB), INTENT(OUT) :: PRESS
TYPE(ONE_D_M_AND_E_XFER_TYPE), INTENT(IN), POINTER :: ONE_D

! Local Variables:
INTEGER :: VIND, EP, INT_NPE_LO, INT_NPE_HI, INPE, ICC, IIG, JJG, KKG

! Cell-centered variables:
VIND=0;  EP  =1
INT_NPE_LO  = CUT_FACE(IND1)%INT_NPE( LOW_IND,VIND,EP,IND2)
INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)
IF (INT_NPE_HI > 0) THEN
   PRESS=0._EB
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      ! PRESS = PRESS + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_CVARS( INT_P_IND,INPE)
      PRESS = PRESS + CUT_FACE(IND1)%INT_COEF(INPE)* &
      CUT_FACE(IND1)%INT_CVARS( INT_RHO_IND,INPE)*CUT_FACE(IND1)%INT_CVARS( INT_H_IND,INPE)
   ENDDO
ELSE
   ! Underlying cell approximate value:
   ICC = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2)
   IIG = CUT_CELL(ICC)%IJK(1)
   JJG = CUT_CELL(ICC)%IJK(2)
   KKG = CUT_CELL(ICC)%IJK(3)
   PRESS=ONE_D%RHO_G*H(IIG,JJG,KKG)
ENDIF

RETURN
END SUBROUTINE GET_PRES_CFACE_TEST

! ------------------------------- CFACE_THERMAL_GASVARS ------------------------------

SUBROUTINE CFACE_THERMAL_GASVARS(ICF,ONE_D)

INTEGER, INTENT(IN) :: ICF
TYPE(ONE_D_M_AND_E_XFER_TYPE), INTENT(INOUT), POINTER :: ONE_D

! Local Variables:
INTEGER :: IND1, IND2, ICC, JCC, I ,J ,K, IFACE, IFC2, IFACE2, NFCELL, ICCF, X1AXIS, LOWHIGH, ILH, IBOD, IWSEL
REAL(EB):: PREDFCT,U_CAVG(IAXIS:KAXIS),AREA_TANG(IAXIS:KAXIS),AF,VELN,NVEC(IAXIS:KAXIS),ABS_NVEC(IAXIS:KAXIS),K_G
REAL(EB):: MU_DNS_G
REAL(EB), POINTER, DIMENSION(:,:,:) :: UP,VP,WP
REAL(EB):: VVEL(IAXIS:KAXIS), V_TANG(IAXIS:KAXIS)
INTEGER :: VIND,EP,INPE,INT_NPE_LO,INT_NPE_HI

! ONE_D%TMP_G, ONE_D%RHO_G, ONE_D%ZZ_G(:), ONE_D%RSUM_G, ONE_D%U_TANG

! Load indexes {ICF,IFACE} in CUT_FACE, for CFACE {ICFACE}:
IND1=CFACE(ICF)%CUT_FACE_IND1
IND2=CFACE(ICF)%CUT_FACE_IND2

! Assign an IOR:
IBOD =CUT_FACE(IND1)%BODTRI(1,IND2)
IWSEL=CUT_FACE(IND1)%BODTRI(2,IND2)
NVEC(IAXIS:KAXIS) = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)
ABS_NVEC(IAXIS:KAXIS) = ABS(NVEC(IAXIS:KAXIS))
X1AXIS = MAXLOC(ABS_NVEC(IAXIS:KAXIS),DIM=1)
ONE_D%IOR = INT(SIGN(1._EB,NVEC(X1AXIS)))*X1AXIS

IF(CFACE_INTERPOLATE) THEN

   ! Cell-centered variables:
   VIND=0;  EP  =1
   INT_NPE_LO  = CUT_FACE(IND1)%INT_NPE( LOW_IND,VIND,EP,IND2)
   INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)

   IF (INT_NPE_HI > 0) THEN
      ONE_D%TMP_G = 0._EB
      ONE_D%RSUM_G= 0._EB
      ONE_D%RHO_G = 0._EB
      ONE_D%ZZ_G(1:N_TRACKED_SPECIES) = 0._EB
      ! Viscosity:
      ONE_D%MU_G = 0._EB
      MU_DNS_G   = 0._EB
      DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
         ONE_D%TMP_G = ONE_D%TMP_G + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_CVARS(  INT_TMP_IND,INPE)
         ONE_D%RSUM_G= ONE_D%RSUM_G+ CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_CVARS( INT_RSUM_IND,INPE)
         ONE_D%RHO_G = ONE_D%RHO_G + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_CVARS(  INT_RHO_IND,INPE)
         ONE_D%MU_G  = ONE_D%MU_G  + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_CVARS(   INT_MU_IND,INPE)
         MU_DNS_G    = MU_DNS_G    + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_CVARS(INT_MUDNS_IND,INPE)
         ONE_D%ZZ_G(1:N_TRACKED_SPECIES) = ONE_D%ZZ_G(1:N_TRACKED_SPECIES) + &
                                           CUT_FACE(IND1)%INT_COEF(INPE)*    &
                                           CUT_FACE(IND1)%INT_CVARS(INT_P_IND+1:INT_P_IND+N_TRACKED_SPECIES,INPE)
      ENDDO

      ! Gas conductivity:
      CALL GET_CCREGION_CELL_CONDUCTIVITY(ONE_D%ZZ_G(1:N_TRACKED_SPECIES),ONE_D%MU_G,MU_DNS_G,ONE_D%TMP_G,K_G)
      ONE_D%K_G = K_G

      ! Finally U_TANG velocity:
      ! U_TANG use the norm of interpolated velocity to EP gas point:
      VVEL(IAXIS:KAXIS) = 0._EB
      DO VIND=IAXIS,KAXIS
         INT_NPE_LO  = CUT_FACE(IND1)%INT_NPE( LOW_IND,VIND,EP,IND2)
         INT_NPE_HI  = CUT_FACE(IND1)%INT_NPE(HIGH_IND,VIND,EP,IND2)
         DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
            VVEL(VIND) = VVEL(VIND) + CUT_FACE(IND1)%INT_COEF(INPE)*CUT_FACE(IND1)%INT_FVARS(INT_VEL_IND,INPE)
         ENDDO
      ENDDO
      V_TANG(IAXIS:KAXIS) = VVEL(IAXIS:KAXIS) - DOT_PRODUCT(VVEL,CFACE(ICF)%NVEC)*CFACE(ICF)%NVEC(IAXIS:KAXIS)
      ONE_D%U_TANG = SQRT(V_TANG(IAXIS)**2._EB+V_TANG(JAXIS)**2._EB+V_TANG(KAXIS)**2._EB)

   ELSE
      CALL CFACE_THVARS_CC
   ENDIF

ELSE
   CALL CFACE_THVARS_CC
ENDIF

RETURN

CONTAINS

SUBROUTINE CFACE_THVARS_CC

IF (PREDICTOR) THEN
   PREDFCT=1._EB
   UP => U ! Corrector final velocities.
   VP => V
   WP => W
ELSE
   PREDFCT=0._EB
   UP => US ! Predictor final velocities.
   VP => VS
   WP => WS
ENDIF


SELECT CASE(CUT_FACE(IND1)%CELL_LIST(1,LOW_IND,IND2))
CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use value from CUT_CELL data struct:

   ICC = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2)
   JCC = CUT_FACE(IND1)%CELL_LIST(3,LOW_IND,IND2)

   I = CUT_CELL(ICC)%IJK(IAXIS)
   J = CUT_CELL(ICC)%IJK(JAXIS)
   K = CUT_CELL(ICC)%IJK(KAXIS)

   ! ADD CUT_CELL properties:
   ONE_D%TMP_G = CUT_CELL(ICC)%TMP(JCC)
   ONE_D%RSUM_G= CUT_CELL(ICC)%RSUM(JCC)

   ! Mixture density and Species mass fractions:
   ONE_D%RHO_G = PREDFCT*CUT_CELL(ICC)%RHOS(JCC) + (1._EB-PREDFCT)*CUT_CELL(ICC)%RHO(JCC)
   ONE_D%ZZ_G(1:N_TRACKED_SPECIES) = PREDFCT *CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC) + &
                              (1._EB-PREDFCT)*CUT_CELL(ICC)% ZZ(1:N_TRACKED_SPECIES,JCC)

   ! Viscosity, Use MU from bearing cartesian cell:
   ONE_D%MU_G = MU(I,J,K)

   ! Gas conductivity:
   CALL GET_CCREGION_CELL_CONDUCTIVITY(ONE_D%ZZ_G(1:N_TRACKED_SPECIES),MU(I,J,K),MU_DNS(I,J,K),ONE_D%TMP_G,K_G)
   ONE_D%K_G = K_G

   ! Finally U_TANG velocity: For now compute the Area average component on each direction:
   ! This can be optimized by moving the computaiton of U_CAVG out, before call to WALL_BC.
   U_CAVG(IAXIS:KAXIS)   = 0._EB
   AREA_TANG(IAXIS:KAXIS)= 0._EB

   NFCELL=CUT_CELL(ICC)%CCELEM(1,JCC)
   DO ICCF=1,NFCELL
      IFACE=CUT_CELL(ICC)%CCELEM(ICCF+1,JCC)
      SELECT CASE(CUT_CELL(ICC)%FACE_LIST(1,IFACE))
      CASE(IBM_FTYPE_RGGAS) ! REGULAR GASPHASE
         LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
         X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)
         ILH     = LOWHIGH - 1
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            AF   = DY(J)*DZ(K)
            VELN = UP(I-1+ILH,J,K)
         CASE(JAXIS)
            AF   = DX(I)*DZ(K)
            VELN = VP(I,J-1+ILH,K)
         CASE(KAXIS)
            AF   = DX(I)*DY(J)
            VELN = WP(I,J,K-1+ILH)
         END SELECT

         U_CAVG(X1AXIS)    =    U_CAVG(X1AXIS) + AF*VELN
         AREA_TANG(X1AXIS) = AREA_TANG(X1AXIS) + AF

      CASE(IBM_FTYPE_CFGAS)
         LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
         IFC2    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
         IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
         X1AXIS  = CUT_FACE(IFC2)%IJK(KAXIS+1)
         AF      = CUT_FACE(IFC2)%AREA(IFACE2)
         VELN    =        PREDFCT *CUT_FACE(IFC2)%VEL( IFACE2) + &
                   (1._EB-PREDFCT)*CUT_FACE(IFC2)%VELS(IFACE2)

         U_CAVG(X1AXIS)    =    U_CAVG(X1AXIS) + AF*VELN
         AREA_TANG(X1AXIS) = AREA_TANG(X1AXIS) + AF

      CASE(IBM_FTYPE_CFINB)
         IFC2    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
         IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)

         AF      = CUT_FACE(IFC2)%AREA(IFACE2)
         ! Normal velocity defined into the body. We want velocity in direction of normal out of bod.
         VELN    = -1._EB*(       PREDFCT *CUT_FACE(IFC2)%VEL( IFACE2) + &
                           (1._EB-PREDFCT)*CUT_FACE(IFC2)%VELS(IFACE2))

         ! Fetch normal out of body on surface triangle this cface lives in:
         IBOD =CUT_FACE(IFC2)%BODTRI(1,IFACE2)
         IWSEL=CUT_FACE(IFC2)%BODTRI(2,IFACE2)
         NVEC(IAXIS:KAXIS) = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)
         DO X1AXIS=IAXIS,KAXIS
            U_CAVG(X1AXIS)    =    U_CAVG(X1AXIS) + AF*VELN*NVEC(X1AXIS)
            AREA_TANG(X1AXIS) = AREA_TANG(X1AXIS) + AF*ABS(NVEC(X1AXIS))
         ENDDO

      END SELECT

   ENDDO
   DO X1AXIS=IAXIS,KAXIS
      IF(AREA_TANG(X1AXIS) > TWO_EPSILON_EB) U_CAVG(X1AXIS) = U_CAVG(X1AXIS) / AREA_TANG(X1AXIS)
   ENDDO

   ! U_TANG use the norm of CC centroid area averaged velocity:
   ONE_D%U_TANG = SQRT( U_CAVG(IAXIS)**2._EB + U_CAVG(JAXIS)**2._EB + U_CAVG(KAXIS)**2._EB )

END SELECT


RETURN
END SUBROUTINE CFACE_THVARS_CC

END SUBROUTINE CFACE_THERMAL_GASVARS

! -------------------------- CCIBM_VELOCITY_CUTFACES ----------------------------

SUBROUTINE CCIBM_VELOCITY_CUTFACES


! Local Variables:
INTEGER  :: NM,ICC,ICF,I,J,K,X1AXIS,NFACE,INDADD,INDF,JCC,IFC,IFACE,IFACE2,CFACE_IND
REAL(EB) :: AREATOT, VEL_CART, FLX_FCT, FSCU
REAL(EB), POINTER, DIMENSION(:,:,:) :: UP,VP,WP

IF (.NOT. PRES_ON_CARTESIAN) RETURN

! Mesh Loop:
MESH_LOOP : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN
      UP => US ! Predictor final velocities.
      VP => VS
      WP => WS
   ELSE
      UP => U ! Corrector final velocities.
      VP => V
      WP => W
   ENDIF

   ! Cut-face Loop:
   ! For now we do area averaging to transfer flux matched velocities to cut-faces:
   ! First GASPHASE cut-faces:
   CUTFACE_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH

      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE

      I      = CUT_FACE(ICF)%IJK(IAXIS)
      J      = CUT_FACE(ICF)%IJK(JAXIS)
      K      = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      NFACE  = CUT_FACE(ICF)%NFACE

      AREATOT= SUM( CUT_FACE(ICF)%AREA(1:NFACE) )

      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         VEL_CART = UP(I,J,K)
         FLX_FCT  = DY(J)*DZ(K)/AREATOT  ! This is Area Cartesian / Sum of cut-face areas.

      CASE(JAXIS)
         VEL_CART = VP(I,J,K)
         FLX_FCT  = DX(I)*DZ(K)/AREATOT  ! This is Area Cartesian / Sum of cut-face areas.

      CASE(KAXIS)
         VEL_CART = WP(I,J,K)
         FLX_FCT  = DY(J)*DX(I)/AREATOT  ! This is Area Cartesian / Sum of cut-face areas.

      END SELECT

      IF (PREDICTOR) THEN
         ! For now assign to all cut-faces same velocity:
         CUT_FACE(ICF)%VELS(1:NFACE) = FLX_FCT*VEL_CART
      ELSE
         CUT_FACE(ICF)%VEL(1:NFACE) = FLX_FCT*VEL_CART
      ENDIF

   ENDDO CUTFACE_LOOP

   ! In case of PERIODIC_TEST = 103, there are no immersed bodies.
   IF(PERIODIC_TEST == 103 .OR. PERIODIC_TEST == 11 .OR. PERIODIC_TEST==7) CYCLE

   ! Then INBOUNDARY cut-faces:
   ! This is only required in the case the pressure solve is done on the whole domain, i.e. FFT solver.
   ! Procedure, for each cut-cell marked Cartesian cell find cell faces tagged as solid, and compute
   ! velocity flux on these. Also compute total area of cut-faces of type INBOUNDARY.
   ! Define average velocity (either in or out) and assign to each INBOUNDARY cut-face.
   PRES_ON_WHOLE_DOMAIN_IF : IF ( PRES_ON_WHOLE_DOMAIN ) THEN

       ! First Cycle over cut-cell underlying Cartesian cells:
       ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH

          I      = CUT_CELL(ICC)%IJK(IAXIS)
          J      = CUT_CELL(ICC)%IJK(JAXIS)
          K      = CUT_CELL(ICC)%IJK(KAXIS)

          IF(SOLID(CELL_INDEX(I,J,K))) CYCLE

          FSCU = 0._EB

          ! Loop on cells neighbors and test if they are of type IBM_SOLID, if so
          ! Add to velocity flux:
          ! X faces
          DO INDADD=-1,1,2
             INDF = I - 1 + (INDADD+1)/2
             IF( FCVAR(INDF,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID) CYCLE
             FSCU = FSCU + REAL(INDADD,EB)*UP(INDF,J,K)*DY(J)*DZ(K)
          ENDDO
          ! Y faces
          DO INDADD=-1,1,2
             INDF = J - 1 + (INDADD+1)/2
             IF( FCVAR(I,INDF,K,IBM_FGSC,JAXIS) /= IBM_SOLID ) CYCLE
             FSCU = FSCU + REAL(INDADD,EB)*VP(I,INDF,K)*DX(I)*DZ(K)
          ENDDO
          ! Z faces
          DO INDADD=-1,1,2
             INDF = K - 1 + (INDADD+1)/2
             IF( FCVAR(I,J,INDF,IBM_FGSC,KAXIS) /= IBM_SOLID ) CYCLE
             FSCU = FSCU + REAL(INDADD,EB)*WP(I,J,INDF)*DX(I)*DY(J)
          ENDDO

          ! Now Define total area of INBOUNDARY cut-faces:
          ICF=CCVAR(I,J,K,IBM_IDCF);

          ICF_COND : IF (ICF > 0) THEN
             NFACE = CUT_FACE(ICF)%NFACE
             AREATOT = SUM ( CUT_FACE(ICF)%AREA(1:NFACE) )
             IF (PREDICTOR) THEN
                DO JCC =1,CUT_CELL(ICC)%NCELL
                   IFC_LOOP : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
                      IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
                      IF (CUT_CELL(ICC)%FACE_LIST(1,IFACE) == IBM_FTYPE_CFINB) THEN
                         IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
                         CUT_FACE(ICF)%VELS(IFACE2) = 1._EB/AREATOT*FSCU ! +ve into the solid Velocity error
                      ENDIF
                   ENDDO IFC_LOOP
                ENDDO
             ELSE ! PREDICTOR
                DO JCC =1,CUT_CELL(ICC)%NCELL
                   IFC_LOOP2 : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
                      IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
                      IF (CUT_CELL(ICC)%FACE_LIST(1,IFACE) == IBM_FTYPE_CFINB) THEN
                         IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
                         CUT_FACE(ICF)%VEL( IFACE2) = 1._EB/AREATOT*FSCU ! +ve into the solid
                         CFACE_IND=CUT_FACE(ICF)%CFACE_INDEX( IFACE2)
                         CFACE(CFACE_IND)%VEL_ERR_NEW=CUT_FACE(ICF)%VEL( IFACE2) - 0._EB ! Assumes zero veloc of solid.
                      ENDIF
                   ENDDO IFC_LOOP2
                ENDDO
             ENDIF
          ENDIF ICF_COND

       ENDDO ICC_LOOP

   ENDIF PRES_ON_WHOLE_DOMAIN_IF

ENDDO MESH_LOOP


RETURN
END SUBROUTINE CCIBM_VELOCITY_CUTFACES


! ----------------------------- CCIBM_RHO0W_INTERP ------------------------------

SUBROUTINE CCIBM_RHO0W_INTERP

! Local Variables:
REAL(EB), POINTER, DIMENSION(:,:,:) :: WP
INTEGER :: NM, ICC, NCELL, ICELL
INTEGER :: I, J ,K, INBFC_CCCEN(1:3)
REAL(EB):: XYZ_PP(MAX_DIM),VAL_CC,VAL_CCW
REAL(EB):: TNOW
INTEGER :: INPE,INT_NPE_LO,INT_NPE_HI,EP,VIND
REAL(EB):: RHO0_EP,RHO0_BP,WCEN_EP,WCEN_BP,COEF_EP,COEF_BP

! This routines interpolates RHO_0 and W velocity component to cut-cell centers,
! It is used when stratification is .TRUE.

IF (.NOT. STRATIFICATION) RETURN
IF (PERIODIC_TEST == 103 .OR. PERIODIC_TEST == 11 .OR. PERIODIC_TEST==7) RETURN

TNOW = CURRENT_TIME()

IF (CC_ZEROIBM_VELO) CC_INJECT_RHO0=.TRUE.

MESH_LOOP : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN
      WP => WS ! End of step velocities.
   ELSE
      WP => W
   ENDIF

   CC_INJECT_RHO0_COND : IF (CC_INJECT_RHO0) THEN
      ICC_LOOP_1 : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         NCELL  = CUT_CELL(ICC)%NCELL
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         ! First RHO_0
         VAL_CC = RHO_0(K)
         DO ICELL=1,NCELL
            XYZ_PP(IAXIS:KAXIS) = CUT_CELL(ICC)%INT_XYZBF(IAXIS:KAXIS,ICELL)
            INBFC_CCCEN(1:3)    = CUT_CELL(ICC)%INT_INBFC(1:3,ICELL)
            CALL GET_BOUND_VEL(KAXIS,INBFC_CCCEN,XYZ_PP,VAL_CCW)
            CUT_CELL(ICC)%RHO_0(ICELL) = VAL_CC
            CUT_CELL(ICC)%WVEL(ICELL)  = VAL_CCW
         ENDDO
      ENDDO ICC_LOOP_1
   ELSE

      VIND = 0
      ICC_LOOP_3 : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         NCELL  = CUT_CELL(ICC)%NCELL
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         RHO0_BP = RHO_0(K)
         DO ICELL=1,NCELL
            RHO0_EP = 0._EB
            WCEN_EP = 0._EB
            DO EP=1,INT_N_EXT_PTS  ! External point for cell ICELL
               INT_NPE_LO = CUT_CELL(ICC)%INT_NPE(LOW_IND,VIND,EP,ICELL)
               INT_NPE_HI = CUT_CELL(ICC)%INT_NPE(HIGH_IND,VIND,EP,ICELL)
               DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                  RHO0_EP = RHO0_EP + CUT_CELL(ICC)%INT_COEF(INPE)* &
                                      CUT_CELL(ICC)%INT_CCVARS(INT_RHO0_IND,INPE)
                  WCEN_EP = WCEN_EP + CUT_CELL(ICC)%INT_COEF(INPE)* &
                                      CUT_CELL(ICC)%INT_CCVARS(INT_WCEN_IND,INPE)
               ENDDO
            ENDDO

            XYZ_PP(IAXIS:KAXIS) = CUT_CELL(ICC)%INT_XYZBF(IAXIS:KAXIS,ICELL)
            INBFC_CCCEN(1:3)    = CUT_CELL(ICC)%INT_INBFC(1:3,ICELL)

            CALL GET_BOUND_VEL(KAXIS,INBFC_CCCEN,XYZ_PP,WCEN_BP)

            COEF_EP = 0._EB
            IF (ABS(CUT_CELL(ICC)%INT_XN(1,ICELL)) > TWO_EPSILON_EB) &
            COEF_EP = CUT_CELL(ICC)%INT_XN(0,ICELL)/CUT_CELL(ICC)%INT_XN(1,ICELL)
            COEF_BP = 1._EB - COEF_EP

            CUT_CELL(ICC)%RHO_0(ICELL) = COEF_BP*RHO0_BP + COEF_EP*RHO0_EP
            CUT_CELL(ICC)%WVEL(ICELL)  = COEF_BP*WCEN_BP + COEF_EP*WCEN_EP

         ENDDO
      ENDDO ICC_LOOP_3

   ENDIF CC_INJECT_RHO0_COND

   NULLIFY(WP)

ENDDO MESH_LOOP

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE CCIBM_RHO0W_INTERP

! ------------------------------- CCIBM_H_INTERP --------------------------------

SUBROUTINE CCIBM_H_INTERP

! Local Variables:
REAL(EB), POINTER, DIMENSION(:,:,:) :: UP,VP,WP,HP
INTEGER :: NM, ICC, NCELL, ICELL, I, J ,K
REAL(EB):: VAL_CC, U_IBM, V_IBM, W_IBM, VCRT
LOGICAL :: VOLFLG
INTEGER :: INPE,INT_NPE_LO,INT_NPE_HI,EP,VIND

! This routine interpolates H to cut cells/Cartesian cells at the end of step.
! Makes use of dH/dXn boundary condition on immersed solid surfaces.

IF (CC_ZEROIBM_VELO) CC_INTERPOLATE_H=.FALSE.

! Interpolate H in cut-cells:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN
      HP => H
      UP => US ! End of step velocities.
      VP => VS
      WP => WS
   ELSE
      HP => HS
      UP => U ! End of step velocities.
      VP => V
      WP => W
   ENDIF

   ! Interpolate to cut-cells. Cut-cell loop:
   ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH

      NCELL  = CUT_CELL(ICC)%NCELL

      I      = CUT_CELL(ICC)%IJK(IAXIS)
      J      = CUT_CELL(ICC)%IJK(JAXIS)
      K      = CUT_CELL(ICC)%IJK(KAXIS)
      VCRT   = DX(I)*DY(J)*DZ(K)

      VOLFLG = .FALSE.
      IF(NCELL > 0) VOLFLG = ABS(VCRT-CUT_CELL(ICC)%VOLUME(1)) < LOOSEPS*VCRT
      IF(PERIODIC_TEST == 103 .OR. PERIODIC_TEST == 11 .OR. PERIODIC_TEST==7 .OR. VOLFLG) THEN
         IF (PREDICTOR) THEN
            CUT_CELL(ICC)%H(1:NCELL) = HP(I,J,K)
         ELSE
            CUT_CELL(ICC)%HS(1:NCELL) = HP(I,J,K)
         ENDIF
         CYCLE
      ENDIF

      ! Now if the Pressure equation has been solved on Cartesian cells, interpolate values of
      ! H to corresponding cut-cell centroids:
      IF (PRES_ON_CARTESIAN) THEN
         IF (CC_INTERPOLATE_H) THEN
            VIND = 0
            DO ICELL=1,NCELL
               VAL_CC = 0._EB
               DO EP=1,INT_N_EXT_PTS  ! External point for cell ICELL
                  INT_NPE_LO = CUT_CELL(ICC)%INT_NPE(LOW_IND,VIND,EP,ICELL)
                  INT_NPE_HI = CUT_CELL(ICC)%INT_NPE(HIGH_IND,VIND,EP,ICELL)
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     VAL_CC = VAL_CC + CUT_CELL(ICC)%INT_COEF(INPE)* &
                                       CUT_CELL(ICC)%INT_CCVARS(INT_H_IND,INPE)
                  ENDDO
               ENDDO
               IF (PREDICTOR) THEN
                  CUT_CELL(ICC)%H(ICELL) = VAL_CC
               ELSE
                  CUT_CELL(ICC)%HS(ICELL) = VAL_CC
               ENDIF
            ENDDO
         ELSE
            VAL_CC    = HP(I,J,K) ! Use underlying value of HP. ! 0._EB
            IF (PREDICTOR) THEN
               CUT_CELL(ICC)%H(1:NCELL) = VAL_CC
            ELSE
               CUT_CELL(ICC)%HS(1:NCELL) = VAL_CC
            ENDIF
         ENDIF
      ENDIF

   ENDDO ICC_LOOP

   ! Finally set HP to zero inside immersed solids:
   IF (.NOT.PRES_ON_WHOLE_DOMAIN) THEN
   DO K=0,KBP1
     DO J=0,JBP1
        DO I=0,IBP1
           IF (MESHES(NM)%CCVAR(I,J,K,IBM_CGSC) /= IBM_SOLID) CYCLE
           HP(I,J,K) = 0._EB
        ENDDO
     ENDDO
   ENDDO
   ENDIF

   ! In case of .NOT. PRES_ON_WHOLE_DOMAIN set velocities on solid faces to zero:
   IF (.NOT.PRES_ON_WHOLE_DOMAIN) THEN
   ! Force U velocities in IBM_SOLID faces to zero
   U_IBM = 0._EB ! Body doesn't move.
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=0,IBAR
            IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID ) CYCLE
            UP(I,J,K) = U_IBM
         ENDDO
      ENDDO
   ENDDO

   ! Force V velocities in IBM_SOLID faces to zero
   V_IBM = 0._EB ! Body doesn't move.
   DO K=1,KBAR
      DO J=0,JBAR
         DO I=1,IBAR
            IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,JAXIS) /= IBM_SOLID ) CYCLE
            VP(I,J,K) = V_IBM
         ENDDO
      ENDDO
   ENDDO

   ! Force W velocities in IBM_SOLID faces to zero
   W_IBM = 0._EB ! Body doesn't move.
   DO K=0,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_SOLID ) CYCLE
            WP(I,J,K) = W_IBM
         ENDDO
      ENDDO
   ENDDO
   ENDIF

   NULLIFY(UP,VP,WP,HP)

ENDDO MESH_LOOP

RETURN
END SUBROUTINE CCIBM_H_INTERP


! --------------------------- CCIBM_INTERP_FACE_VEL -----------------------------

SUBROUTINE CCIBM_INTERP_FACE_VEL(DT,NM,STORE_FLG)


USE TURBULENCE, ONLY : WALL_MODEL
USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY

! This routine is used to interpolate velocities in Cartesian Faces of type IBM_CUTCFE
! (containing GASPHASE cut-faces), such that shear stresses used in momentum evolution
! for surrounding regular cells are accurate.
! It assumes POINT_TO_MESH(NM) has already been called, and that required previous step
! velocities have been filled in CUT_FACE(ICF)%VEL_CARTCEN, CUT_FACE(ICF)%VELS_CARTCEN.
! Viscosity in cut-cells underlaying Cartesian cells is assumed previously computed.

REAL(EB),INTENT(IN) :: DT
INTEGER, INTENT(IN) :: NM
LOGICAL, INTENT(IN) :: STORE_FLG

! Local Variables:
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU,VV,WW
INTEGER :: ICF,IW,I,J,K,X1AXIS

REAL(EB) :: U_IBM,UVW_EP(IAXIS:KAXIS,0:INT_N_EXT_PTS,0:0)
REAL(EB) :: U_VELO(MAX_DIM),U_SURF(MAX_DIM),U_RELA(MAX_DIM)
REAL(EB) :: NN(MAX_DIM),SS(MAX_DIM),TT(MAX_DIM),VELN,U_NORM,U_NORM2,U_ORTH,U_STRM,U_STRM2,VAL_EP
INTEGER :: IFACE, EP, VIND, INPE, ICF1, ICF2, ICFA, INT_NPE_LO, INT_NPE_HI
REAL(EB):: DXN_STRM, DXN_STRM2, COEF

REAL(EB):: X1F, IDX, CCM1, CCP1, TMPV(-1:0), RHOV(-1:0), MUV(-1:0), NU, MU_FACE, RHO_FACE, PRFCT
REAL(EB):: ZZ_GET(1:N_TRACKED_SPECIES), SLIP_FACTOR, U_TAU, Y_PLUS, SRGH, DUSDN_FP
! REAL(EB):: MU_T, TAU_WALL, TAU_OFF_WALL
INTEGER :: ICC,JCC,ISIDE
REAL(EB):: DT2

REAL(EB) :: TNOW

DT2 = 0._EB*DT

IF ( FREEZE_VELOCITY ) RETURN
IF ( CC_ZEROIBM_VELO ) RETURN
IF (PERIODIC_TEST == 103 .OR. PERIODIC_TEST == 11 .OR. PERIODIC_TEST==7) RETURN
TNOW = CURRENT_TIME()

IF (PREDICTOR) THEN
   UU => U
   VV => V
   WW => W
   PRFCT = 0._EB
ELSE
   UU => US
   VV => VS
   WW => WS
   PRFCT = 1._EB
ENDIF

STORE_FLG_CND : IF (STORE_FLG) THEN

   CUTFACE_LOOP_1 : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE CUTFACE_LOOP_1
      ! Do not interpolate in External Boundaries, type SOLID or MIRROR.
      IW = CUT_FACE(ICF)%IWC
      IF ( (IW > 0) .AND. (WALL(IW)%BOUNDARY_TYPE==SOLID_BOUNDARY   .OR. &
                           WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY    .OR. &
                           WALL(IW)%BOUNDARY_TYPE==MIRROR_BOUNDARY) ) CYCLE CUTFACE_LOOP_1
      I      = CUT_FACE(ICF)%IJK(IAXIS)
      J      = CUT_FACE(ICF)%IJK(JAXIS)
      K      = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
      UVW_EP = 0._EB
      ! Interpolate Un+1 approx to External Points:
      IFACE=0; VAL_EP=0._EB
      DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
         DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
            INT_NPE_LO = CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
            INT_NPE_HI = CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
            DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
               ! Value of velocity component VIND, for stencil point INPE of external normal point EP.
               IF (PREDICTOR) VAL_EP = CUT_FACE(ICF)%INT_FVARS(INT_VEL_IND,INPE)
               IF (CORRECTOR) VAL_EP = CUT_FACE(ICF)%INT_FVARS(INT_VELS_IND,INPE)
               ! Interpolation coefficient from INPE to EP.
               COEF = CUT_FACE(ICF)%INT_COEF(INPE)
               ! Add to Velocity component VIND of EP:
               UVW_EP(VIND,EP,IFACE) = UVW_EP(VIND,EP,IFACE) + COEF*VAL_EP
            ENDDO
         ENDDO
      ENDDO

      IF(INT_N_EXT_PTS==1) THEN
         ! Transform External points velocities into local coordinate system, defined by the velocity vector in
         ! the first external point, and the surface:
         EP = 1
         U_VELO(IAXIS:KAXIS) = UVW_EP(IAXIS:KAXIS,EP,IFACE)
         VELN = 0._EB
         SRGH = 0._EB
         IF( CUT_FACE(ICF)%INT_INBFC(1,IFACE)== IBM_FTYPE_CFINB) THEN
            ICF1 = CUT_FACE(ICF)%INT_INBFC(2,IFACE)
            ICF2 = CUT_FACE(ICF)%INT_INBFC(3,IFACE)
            ICFA = CUT_FACE(ICF1)%CFACE_INDEX(ICF2)
            IF (ICFA>0) THEN
               VELN = -CFACE(ICFA)%ONE_D%U_NORMAL
               SRGH = SURFACE(CFACE(ICFA)%SURF_INDEX)%ROUGHNESS
            ENDIF
         ENDIF

         NN(IAXIS:KAXIS)     = CUT_FACE(ICF)%INT_NOUT(IAXIS:KAXIS,IFACE)
         TT=0._EB; SS=0._EB; U_NORM=0._EB; U_ORTH=0._EB; U_STRM=0._EB; U_IBM = 0._EB
         IF (NORM2(NN) > TWO_EPSILON_EB) THEN
            U_SURF(IAXIS:KAXIS) = VELN*NN
            U_RELA(IAXIS:KAXIS) = U_VELO(IAXIS:KAXIS)-U_SURF(IAXIS:KAXIS)
            ! Gives local velocity components U_STRM , U_ORTH , U_NORM in terms of unit vectors
            ! SS,TT,NN
            CALL GET_LOCAL_VELOCITY(U_RELA,NN,TT,SS,U_NORM,U_ORTH,U_STRM)
            ! U_STRM    = U_RELA(X1AXIS)
            ! SS(X1AXIS)= 1._EB ! Make stream the X1AXIS dir.

            SLIPVEL_CONDITIONAL : IF(CC_SLIPIBM_VELO) THEN
               ! Slip condition: Make FP velocities equal to EP values.
               U_STRM2 = U_STRM
               U_NORM2 = U_NORM

            ELSE SLIPVEL_CONDITIONAL

               ! Apply wall model to define streamwise velocity at interpolation point:
               DXN_STRM =CUT_FACE(ICF)%INT_XN(EP,IFACE) ! EP Position from Boundary in NOUT direction
               DXN_STRM2=CUT_FACE(ICF)%INT_XN(0,IFACE)  ! Interpolation point position from Bound in NOUT dir.
                                                        ! If this is a -ve number (i.e. case of Cartesian Faces),
                                                        ! Linear velocity variation should be used be used.
               ! Linear variation:
               U_NORM2 = DXN_STRM2/DXN_STRM*U_NORM      ! Assumes relative U_normal decreases linearly to boundry.

               X1F= MESHES(NM)%CUT_FACE(ICF)%XYZCEN(X1AXIS,1)
               IDX= 1._EB/ ( MESHES(NM)%CUT_FACE(ICF)%XCENHIGH(X1AXIS,1) - &
                             MESHES(NM)%CUT_FACE(ICF)%XCENLOW(X1AXIS, 1) )
               CCM1= IDX*(MESHES(NM)%CUT_FACE(ICF)%XCENHIGH(X1AXIS,1)-X1F)
               CCP1= IDX*(X1F-MESHES(NM)%CUT_FACE(ICF)%XCENLOW(X1AXIS, 1))
               ! For NU use interpolation of values on neighboring cut-cells:
               TMPV(-1:0) = -1._EB; RHOV(-1:0) = 0._EB
               DO ISIDE=-1,0
                  ZZ_GET = 0._EB
                  SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,1))
                  CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                     ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,1)
                     JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,1)
                     TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
                     ZZ_GET(1:N_TRACKED_SPECIES) =  &
                            PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                     (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
                     RHOV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
                            (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
                  END SELECT
                  CALL GET_VISCOSITY(ZZ_GET,MUV(ISIDE),TMPV(ISIDE))
               ENDDO
               MU_FACE = CCM1* MUV(-1) + CCP1* MUV(0)
               RHO_FACE= CCM1*RHOV(-1) + CCP1*RHOV(0)
               NU      = MU_FACE/RHO_FACE
               CALL WALL_MODEL(SLIP_FACTOR,U_TAU,Y_PLUS,NU,SRGH,DXN_STRM,U_STRM,ABS(DXN_STRM2),U_STRM2,DUSDN_FP)

               ! If Cartesian face centroid inside the solid (i.e. acts like ghost cell) recompute U_STRM2
               ! using slip factor:
               IF(DXN_STRM2 < 0._EB) U_STRM2 = SLIP_FACTOR*ABS(DXN_STRM2)/DXN_STRM*U_STRM

            ENDIF SLIPVEL_CONDITIONAL

            ! Velocity U_ORTH is zero by construction. Surface velocity is added to get absolute vel.
            U_IBM = U_NORM2*NN(X1AXIS) + U_STRM2*SS(X1AXIS) + U_SURF(X1AXIS)

         ENDIF
      ENDIF

      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         ! Store UU value:
         CUT_FACE(ICF)%VELINT_CRF = UU(I,J,K)
         ! Assign U_IBM to UU for stress computation in VELOCITY_FLUX:
         UU(I,J,K) = U_IBM
      CASE(JAXIS)
         ! Store VV value:
         CUT_FACE(ICF)%VELINT_CRF = VV(I,J,K)
         ! Assign U_IBM to VV for stress computation in VELOCITY_FLUX:
         VV(I,J,K) = U_IBM
      CASE(KAXIS)
         ! Store WW value:
         CUT_FACE(ICF)%VELINT_CRF = WW(I,J,K)
         ! Assign U_IBM to WW for stress computation in VELOCITY_FLUX:
         WW(I,J,K) = U_IBM
      END SELECT
   ENDDO CUTFACE_LOOP_1

ELSE
   ! Restore velocities to Cartesian faces:
   CUTFACE_LOOP_2 : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE CUTFACE_LOOP_2
      ! Do not interpolate in External Boundaries, type SOLID or MIRROR.
      IW = CUT_FACE(ICF)%IWC
      IF ( (IW > 0) .AND. (WALL(IW)%BOUNDARY_TYPE==SOLID_BOUNDARY   .OR. &
                           WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY    .OR. &
                           WALL(IW)%BOUNDARY_TYPE==MIRROR_BOUNDARY) ) CYCLE CUTFACE_LOOP_2
      I      = CUT_FACE(ICF)%IJK(IAXIS)
      J      = CUT_FACE(ICF)%IJK(JAXIS)
      K      = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         UU(I,J,K) = CUT_FACE(ICF)%VELINT_CRF
      CASE(JAXIS)
         VV(I,J,K) = CUT_FACE(ICF)%VELINT_CRF
      CASE(KAXIS)
         WW(I,J,K) = CUT_FACE(ICF)%VELINT_CRF
      END SELECT
   ENDDO CUTFACE_LOOP_2

ENDIF STORE_FLG_CND

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(CCIBM_INTERP_FACE_VEL_TIME_INDEX) = T_CC_USED(CCIBM_INTERP_FACE_VEL_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE CCIBM_INTERP_FACE_VEL


! ----------------------------- CCCOMPUTE_RADIATION --------------------------------

SUBROUTINE CCCOMPUTE_RADIATION(T,NM,ITER)

! This is a temporary container where to add QR=-CHI_R*Q

INTEGER, INTENT(IN) :: NM,ITER
REAL(EB), INTENT(IN) :: T

! Local Variables:
INTEGER ICC, JCC, I, J, K, NCELL
REAL(EB):: DUMMY1
INTEGER :: DUMMY2
REAL(EB) :: TNOW, CCVOL_TOT

DUMMY1=T
DUMMY2=ITER

TNOW = CURRENT_TIME()

IF(.NOT.RADIATION) THEN
   IF (N_REACTIONS>0) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         DO JCC=1,CUT_CELL(ICC)%NCELL
            CUT_CELL(ICC)%QR(JCC) = -CUT_CELL(ICC)%CHI_R(JCC)*CUT_CELL(ICC)%Q(JCC)
         ENDDO
      ENDDO
   ENDIF
ELSE
    ! Solution for QR in underlaying Cartesian cell, coming from RADIATION_FVM
    DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
       I = CUT_CELL(ICC)%IJK(IAXIS)
       J = CUT_CELL(ICC)%IJK(JAXIS)
       K = CUT_CELL(ICC)%IJK(KAXIS)
       NCELL = CUT_CELL(ICC)%NCELL
       CCVOL_TOT=SUM(CUT_CELL(ICC)%VOLUME(1:NCELL))
       DO JCC=1,CUT_CELL(ICC)%NCELL
          ! The conversion factor is s.t. QR(I,J,K)*(DX(I)*DY(J)*DZ(K)) = sum_JCC( CUT_CELL(ICC)%QR(JCC) *VOLUME(JCC) ).
          CUT_CELL(ICC)%QR(JCC) = QR(I,J,K)*(DX(I)*DY(J)*DZ(K))/CCVOL_TOT
       ENDDO
    ENDDO
ENDIF

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(CCCOMPUTE_RADIATION_TIME_INDEX) = T_CC_USED(CCCOMPUTE_RADIATION_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE CCCOMPUTE_RADIATION


! -------------------------------- CCIBM_SET_DATA ----------------------------------

SUBROUTINE CCIBM_SET_DATA(FIRST_CALL)

LOGICAL, INTENT(IN) :: FIRST_CALL

! Local Variables:
INTEGER :: NM,ICALL
REAL(EB):: LX,LY,LZ,MAX_DIST
REAL(EB):: TNOW,TNOW2,TDEL,MIN_XS(1:3),MAX_XF(1:3)

INTEGER :: ICF
CHARACTER(80) :: FN_CCTIME
CHARACTER(200)::TCFORM

TNOW2 = CURRENT_TIME()

SET_CUTCELLS_CALL_IF : IF(FIRST_CALL) THEN

! Plane by plane Evaluation of stesses for IBEDGES, a la OBSTS.
IF(CC_STRESS_METHOD) CC_ONLY_IBEDGES_FLAG=.FALSE.

IF (N_GEOMETRY==0 .AND. .NOT.(PERIODIC_TEST==103 .OR. PERIODIC_TEST==11 .OR. PERIODIC_TEST==7)) THEN
   IF (MY_RANK==0) THEN
      WRITE(LU_ERR,*) ' '
      WRITE(LU_ERR,*) 'CCIBM Setup Error : &MISC CC_IBM=.TRUE., but no &GEOM namelist defined on input file.'
      WRITE(LU_ERR,*) ' '
   ENDIF
   STOP_STATUS = SETUP_STOP
   RETURN
ENDIF

! Defined relative GEOMEPS:
! Find largest domain distance to define relative epsilon:
MIN_XS(1:3) = (/ MESHES(1)%XS, MESHES(1)%YS, MESHES(1)%ZS /)
MAX_XF(1:3) = (/ MESHES(1)%XF, MESHES(1)%YF, MESHES(1)%ZF /)
DO NM=2,NMESHES
   MIN_XS(1) = MIN(MIN_XS(1),MESHES(NM)%XS)
   MIN_XS(2) = MIN(MIN_XS(2),MESHES(NM)%YS)
   MIN_XS(3) = MIN(MIN_XS(3),MESHES(NM)%ZS)
   MAX_XF(1) = MAX(MAX_XF(1),MESHES(NM)%XF)
   MAX_XF(2) = MAX(MAX_XF(2),MESHES(NM)%YF)
   MAX_XF(3) = MAX(MAX_XF(3),MESHES(NM)%ZF)
ENDDO
LX = MAX_XF(1) - MIN_XS(1)
LY = MAX_XF(2) - MIN_XS(2)
LZ = MAX_XF(3) - MIN_XS(3)
MAX_DIST=MAX(LX,LY,LZ)


! Set relative epsilon for cut-cell definition:
MAX_DIST= MAX(1._EB,MAX_DIST)
GEOMEPS = GEOMEPS*MAX_DIST

! Set Flux limiter for cut-cell region:
IF(I_FLUX_LIMITER==CENTRAL_LIMITER) THEN
   BRP1 = 1._EB ! If 0., Godunov for advective term; if 1., centered interp.
ELSE ! For any other flux limiter use Godunov in CC region.
   BRP1 = 0._EB ! If 0., Godunov for advective term; if 1., centered interp.
ENDIF

IF (PERIODIC_TEST == 105) THEN ! Set cc-guard to zero, i.e. do not compute guard-cell cut-cells, for timings.
   NGUARD = 2
   CCGUARD= NGUARD-2
ENDIF

TNOW = CURRENT_TIME()
CALL SET_CUTCELLS_3D                    ! Defines CUT_CELL data for each mesh.
IF (STOP_STATUS==SETUP_STOP) RETURN

TDEL = CURRENT_TIME() - TNOW

IF (PERIODIC_TEST == 105) THEN ! Cut-cell definition timings test.
    IF(MY_RANK==0) WRITE(LU_ERR,*) ' '
    ICALL = 1
    IF(MY_RANK==0) WRITE(LU_ERR,*) 'CALL number ',ICALL,' to SET_CUTCELLS_3D finished. Max Time=',TDEL,' sec.'
    DO ICALL=2,N_SET_CUTCELLS_3D_CALLS
       TNOW = CURRENT_TIME()
       CALL SET_CUTCELLS_3D                    ! Defines CUT_CELL data for each mesh, average timings.
       TDEL = CURRENT_TIME() - TNOW
       IF(MY_RANK==0) WRITE(LU_ERR,*) 'CALL number ',ICALL,' to SET_CUTCELLS_3D finished. Max Time=',TDEL,' sec.'
    ENDDO
    WRITE_SET_CUTCELLS_TIMINGS = .TRUE.
    COMPUTE_CUTCELLS_ONLY =.TRUE.
ENDIF

! Write out SET_CUTCELLS_3D loop time:
IF (WRITE_SET_CUTCELLS_TIMINGS) THEN

   ! Total number of cut-cells and faces computed does not consider guard-cells:
   N_CUTCELLS_PROC     = 0
   N_INB_CUTFACES_PROC = 0
   N_REG_CUTFACES_PROC = 0
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL POINT_TO_MESH(NM)
      ! Cut-cells:
      N_CUTCELLS_PROC = N_CUTCELLS_PROC + MESHES(NM)%N_CUTCELL_MESH
      ! Cut-faces:
      DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
         SELECT CASE(CUT_FACE(ICF)%STATUS)
         CASE(IBM_GASPHASE)
            N_REG_CUTFACES_PROC = N_REG_CUTFACES_PROC + CUT_FACE(ICF)%NFACE
         CASE(IBM_INBOUNDARY)
            N_INB_CUTFACES_PROC = N_INB_CUTFACES_PROC + CUT_FACE(ICF)%NFACE
         END SELECT
      ENDDO
   ENDDO

   ! Write xxx_cc_cpu_0001.csv
   ! This csv file contains the following fields (14):
   ! N_CUTCELLS, N_INB_CUTFACES, N_REG_CUTFACES, SET_CUTCELLS_TIME, GET_BODINT_PLANE_TIME, GET_X2_INTERSECTIONS_TIME, &
   ! GET_X2_VERTVAR_TIME, GET_CARTEDGE_CUTEDGES_TIME, GET_BODX2X3_INTERSECTIONS_TIME, GET_CARTFACE_CUTEDGES_TIME, &
   ! GET_CARTCELL_CUTEDGES_TIME, GET_CARTFACE_CUTFACES_TIME, GET_CARTCELL_CUTFACES_TIME, GET_CARTCELL_CUTCELLS_TIME
   WRITE(FN_CCTIME,'(A,A,I3.3,A)') TRIM(CHID),'_cc_cpu_',MY_RANK,'.csv'
   OPEN(333,FILE=TRIM(FN_CCTIME),STATUS='UNKNOWN')
   WRITE(333,'(A,A,A,A)') "N_CUTCELLS, N_INB_CUTFACES, N_REG_CUTFACES, SET_CUTCELLS_TIME, GET_BODINT_PLANE_TIME, ",   &
                          "GET_X2_INTERSECTIONS_TIME, GET_X2_VERTVAR_TIME, GET_CARTEDGE_CUTEDGES_TIME, ",             &
                          "GET_BODX2X3_INTERSECTIONS_TIME, GET_CARTFACE_CUTEDGES_TIME, GET_CARTCELL_CUTEDGES_TIME, ", &
                          "GET_CARTFACE_CUTFACES_TIME, GET_CARTCELL_CUTFACES_TIME, GET_CARTCELL_CUTCELLS_TIME"
   WRITE(TCFORM,'(23A)')  "(I6,',',I6,',',I6,',',",FMT_R,",',',",FMT_R,",',',",FMT_R,",',',",FMT_R,",',',",           &
                          FMT_R,",',',",FMT_R,",',',",FMT_R,",',',",FMT_R,",',',",FMT_R,",',',",FMT_R,",',',",FMT_R,")"
   WRITE(333,TCFORM) N_CUTCELLS_PROC,N_INB_CUTFACES_PROC,N_REG_CUTFACES_PROC, &
                     T_CC_USED(SET_CUTCELLS_TIME_INDEX:GET_CARTCELL_CUTCELLS_TIME_INDEX)/ &
                     REAL(N_SET_CUTCELLS_3D_CALLS,EB)
   CLOSE(333)


   IF (MY_RANK == 0) THEN
      WRITE(LU_ERR,*) ' '
      WRITE(LU_ERR,*) 'Spheres NVERTS,NFACES',GEOMETRY(1)%N_VERTS,GEOMETRY(1)%N_FACES
      WRITE(LU_ERR,*) 'SET_CUTCELLS_3D loop time by process ',MY_RANK,' =',T_CC_USED(SET_CUTCELLS_TIME_INDEX), &
                      ' sec., cut-cells=',N_CUTCELLS_PROC,', cut-faces=',N_INB_CUTFACES_PROC,N_REG_CUTFACES_PROC
   ENDIF
ENDIF

IF (COMPUTE_CUTCELLS_ONLY) THEN
   STOP_STATUS = SETUP_ONLY_STOP
   RETURN
ENDIF

ELSE SET_CUTCELLS_CALL_IF

IF (GET_CUTCELLS_VERBOSE .AND. MY_RANK==0) THEN
   CALL CPU_TIME(TNOW)
ENDIF

! Redefine wall_cells inside Geoms: This is done before EDGE info as edges with WALL_CELL type NULL_BOUNDARY will be taken
! care of by GEOM edges. Note EDGE_INDEX will be reassigned the IBEDGE position in OME_E, TAU_E arrays for velocity flux to
! be computed correctly.
CALL BLOCK_IBM_SOLID_EXTWALLCELLS

IF(CC_STRESS_METHOD) THEN
   ! ALLOCATE CELL_COUNT_CC, N_EDGES_DIM_CC:
   ALLOCATE(CELL_COUNT_CC(1:NMESHES));      CELL_COUNT_CC  = 0
   ALLOCATE(N_EDGES_DIM_CC(1:2,1:NMESHES)); N_EDGES_DIM_CC = 0
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      ! Define CELL_COUNT_CC(NM), N_EDGES_DIM_CC(1:2,NM), reallocate and populate FDS edge and cell topology variables
      MESHES(NM)%ECVAR(:,:,:,IBM_IDCE,:) = IBM_UNDEFINED
      IF(.NOT.CC_ONLY_IBEDGES_FLAG) CALL GET_REGULAR_CUTCELL_EDGES_BC(NM)
      CALL GET_SOLID_CUTCELL_EDGES_BC(NM)
   ENDDO
ENDIF

CALL GET_CRTCFCC_INT_STENCILS ! Computes interpolation stencils for face and cell centers.
IF (GET_CUTCELLS_VERBOSE .AND. MY_RANK==0) THEN
   CALL CPU_TIME(TDEL)
   WRITE(LU_ERR,'(A,F8.3,A)') ' Executed GET_CRTCFCC_INT_STENCILS. Time taken : ',TDEL-TNOW,' sec.'
ENDIF
CALL SET_CCIBM_MATVEC_DATA              ! Defines data for discretization matrix-vectors.
IF (GET_CUTCELLS_VERBOSE .AND. MY_RANK==0) THEN
   CALL CPU_TIME(TNOW)
   WRITE(LU_ERR,'(A,F8.3,A)') ' Executing SET_CCIBM_MATVEC_DATA. Time taken : ',TNOW-TDEL,' sec.'
ENDIF
CALL SET_CFACES_ONE_D_RDN               ! Set inverse DXN for CFACES, uses cell linking information.
IF (GET_CUTCELLS_VERBOSE .AND. MY_RANK==0) THEN
   CALL CPU_TIME(TDEL)
   WRITE(LU_ERR,'(A,F8.3,A)') ' Executing SET_CFACES_ONE_D_RDN. Time taken : ',TDEL-TNOW,' sec.'
ENDIF

IF(GET_CUTCELLS_VERBOSE) CLOSE(LU_SETCC)

! Set flag that specifies cut-cell data as defined:
CC_MATVEC_DEFINED=.TRUE.

ENDIF SET_CUTCELLS_CALL_IF

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW2

IF (TIME_CC_IBM) T_CC_USED(CCIBM_SET_DATA_TIME_INDEX) = T_CC_USED(CCIBM_SET_DATA_TIME_INDEX) + CURRENT_TIME() - TNOW2
RETURN

CONTAINS

! ------------------------ SET_CFACES_ONE_D_RDN ---------------------------------

SUBROUTINE SET_CFACES_ONE_D_RDN

! Local Variables:
INTEGER :: ICF, IFACE, CFACE_INDEX_LOCAL
INTEGER :: ICC, JCC, IBOD, IWSEL, I, J, K
INTEGER :: ILO, IHI, JLO, JHI, KLO, KHI, IFACE_CELL, ICF_CELL, IROW, NCELL, ICF1, ICF2
REAL(EB):: DXCF(IAXIS:KAXIS), NVEC(IAXIS:KAXIS), DCFXN, DCFXN2, DCFXNI, AREAI
REAL(EB), ALLOCATABLE, DIMENSION(:) :: DXN_UNKZ_LOC
REAL(EB), ALLOCATABLE, DIMENSION(:) :: VOL_UNKZ_LOC
INTEGER, ALLOCATABLE, DIMENSION(:,:):: IJK_UNKZ_LOC


IF (.NOT.CFACE_INTERPOLATE) THEN

   ! ALLOCATE local arrays
   ALLOCATE(DXN_UNKZ_LOC(1:NUNKZ_LOCAL)); DXN_UNKZ_LOC(:) = 0._EB
   ALLOCATE(VOL_UNKZ_LOC(1:NUNKZ_LOCAL)); VOL_UNKZ_LOC(:) = 0._EB
   ALLOCATE(IJK_UNKZ_LOC(IAXIS:KAXIS+1,1:NUNKZ_LOCAL)); IJK_UNKZ_LOC(:,:) = IBM_UNDEFINED

   ! Main Loop:
   MESH_LOOP_1 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

      CALL POINT_TO_MESH(NM)

      ! Do a volume weighted average of distance to wall from linked cells, if one of them is a regular cell use 1/2 the
      ! distance of corner to corner sqrt(DX^2+DY^2+DZ^2).
      ! 1. Regular GASPHASE cells within the cc-region:
      ILO = 1; IHI = IBAR
      JLO = 1; JHI = JBAR
      KLO = 1; KHI = KBAR
      DO K=KLO,KHI
         DO J=JLO,JHI
            DO I=ILO,IHI
               IF (CCVAR(I,J,K,IBM_UNKZ) <= 0 ) CYCLE ! Drop if regular gas cell has not been assigned unknown number.
               IROW = CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
               DXN_UNKZ_LOC(IROW) = DXN_UNKZ_LOC(IROW) + 1._EB/3._EB*(DX(I)+DY(J)+DZ(K))*(DX(I)*DY(J)*DZ(K)) !Avg Delta.
               VOL_UNKZ_LOC(IROW) = VOL_UNKZ_LOC(IROW) + (DX(I)*DY(J)*DZ(K))
               IJK_UNKZ_LOC(IAXIS:KAXIS+1,IROW) = (/ I,J,K,NM /)
            ENDDO
         ENDDO
      ENDDO
      ! 2. Number cut-cells:
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I = CUT_CELL(ICC)%IJK(IAXIS)
         J = CUT_CELL(ICC)%IJK(JAXIS)
         K = CUT_CELL(ICC)%IJK(KAXIS)
         NCELL = CUT_CELL(ICC)%NCELL
         DO JCC=1,NCELL
            IROW = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            ! Mean INBOUNDARY cut-face distance to this cut-cell center, projected to cut-face normal:
            AREAI = 0._EB
            DCFXNI= 0._EB
            DO ICF_CELL=1,CUT_CELL(ICC)%CCELEM(1,JCC)
               IFACE_CELL = CUT_CELL(ICC)%CCELEM(ICF_CELL+1,JCC)
               IF (CUT_CELL(ICC)%FACE_LIST(1,IFACE_CELL) /= IBM_FTYPE_CFINB) CYCLE

               ! Indexes of INBOUNDARY cutface on CUT_FACE:
               ICF   = CUT_CELL(ICC)%FACE_LIST(4,IFACE_CELL)
               IFACE = CUT_CELL(ICC)%FACE_LIST(5,IFACE_CELL)

               ! DXN:
               ! Xcc - Xcf:
               DXCF(IAXIS:KAXIS) = CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC) - CUT_FACE(ICF)%XYZCEN(IAXIS:KAXIS,IFACE)

               ! Normal to cut-face:
               IBOD =CUT_FACE(ICF)%BODTRI(1,IFACE)
               IWSEL=CUT_FACE(ICF)%BODTRI(2,IFACE)
               NVEC(IAXIS:KAXIS) = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)

               ! Dot product gives normal distance from Xcf to Xcc:
               DCFXN = ABS(DXCF(IAXIS)*NVEC(IAXIS) + DXCF(JAXIS)*NVEC(JAXIS) + DXCF(KAXIS)*NVEC(KAXIS))
               IF (DCFXN < GEOMEPS) DCFXN=SQRT(DXCF(IAXIS)**2._EB+DXCF(JAXIS)**2._EB+DXCF(KAXIS)**2._EB) ! Norm Xcc-Xcf
               IF (DCFXN < GEOMEPS) DCFXN=0.5_EB*ABS(NVEC(IAXIS)*DX(I)+NVEC(JAXIS)*DY(J)+NVEC(KAXIS)*DZ(K)) ! CRT cell

               ! Area sum:
               AREAI = AREAI + CUT_FACE(ICF)%AREA(IFACE)
               ! DXN*Area sume:
               DCFXNI= DCFXNI+ DCFXN*CUT_FACE(ICF)%AREA(IFACE)
            ENDDO

            IF (AREAI < GEOMEPS) THEN ! This cut cell has the size and geometry of a regular cell.
               DXN_UNKZ_LOC(IROW) = DXN_UNKZ_LOC(IROW) + 1._EB/3._EB*(DX(I)+DY(J)+DZ(K))*(DX(I)*DY(J)*DZ(K))
               VOL_UNKZ_LOC(IROW) = VOL_UNKZ_LOC(IROW) + (DX(I)*DY(J)*DZ(K))
            ELSE
               ! INBOUNDARY cut-face area Average:
               DCFXNI= DCFXNI / AREAI
               ! Center to center distance:
               DCFXN2 = 2._EB*(DCFXNI)
               DXN_UNKZ_LOC(IROW) = DXN_UNKZ_LOC(IROW) + DCFXN2*CUT_CELL(ICC)%VOLUME(JCC)
               VOL_UNKZ_LOC(IROW) = VOL_UNKZ_LOC(IROW) + CUT_CELL(ICC)%VOLUME(JCC)
            ENDIF
            IJK_UNKZ_LOC(IAXIS:KAXIS+1,IROW) = (/ I,J,K,NM /)
         ENDDO
      ENDDO

   ENDDO MESH_LOOP_1

   ! Compute volume average for all linked cells:
   DO IROW=1,NUNKZ_LOCAL
      IF ( VOL_UNKZ_LOC(IROW) < GEOMEPS ) THEN
         I  = IJK_UNKZ_LOC(IAXIS,IROW)
         J  = IJK_UNKZ_LOC(JAXIS,IROW)
         K  = IJK_UNKZ_LOC(KAXIS,IROW)
         NM = IJK_UNKZ_LOC(KAXIS+1,IROW)
         DXN_UNKZ_LOC(IROW) = 1._EB/3._EB*( MESHES(NM)%DX(I) + MESHES(NM)%DY(J) + MESHES(NM)%DZ(K) )
         CYCLE
      ENDIF
      DXN_UNKZ_LOC(IROW) = DXN_UNKZ_LOC(IROW) / VOL_UNKZ_LOC(IROW)
   ENDDO


   ! Finally Define ONE_D%RDN:
   MESH_LOOP_2 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL POINT_TO_MESH(NM)
      DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
         IF(CUT_FACE(ICF)%STATUS /= IBM_INBOUNDARY) CYCLE
         DO IFACE=1,CUT_FACE(ICF)%NFACE
            ! Index in CFACE for cut-face in (ICF,IFACE) of CUT_FACE.
            CFACE_INDEX_LOCAL = CUT_FACE(ICF)%CFACE_INDEX(IFACE)
            ! Compute CFACE(:)%ONE_D%RDN:
            IF (CUT_FACE(ICF)%CELL_LIST(1,LOW_IND,IFACE) /= IBM_FTYPE_CFGAS) CYCLE
            ICC = CUT_FACE(ICF)%CELL_LIST(2,LOW_IND,IFACE)
            JCC = CUT_FACE(ICF)%CELL_LIST(3,LOW_IND,IFACE)
            IROW = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            CFACE(CFACE_INDEX_LOCAL)%ONE_D%RDN = 1._EB/DXN_UNKZ_LOC(IROW)
         ENDDO
      ENDDO
   ENDDO MESH_LOOP_2
   DEALLOCATE(DXN_UNKZ_LOC, VOL_UNKZ_LOC, IJK_UNKZ_LOC)

ELSE ! CFACE_INTERPOLATE

   MESH_LOOP_3 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL POINT_TO_MESH(NM)
      DO ICF=1,N_CFACE_CELLS
         ICF1 = CFACE(ICF)%CUT_FACE_IND1
         ICF2 = CFACE(ICF)%CUT_FACE_IND2
         IF(CUT_FACE(ICF1)%INT_XN(1,ICF2) < TWO_EPSILON_EB) THEN
            CFACE(ICF)%ONE_D%RDN = 1._EB/DX(1)
         ELSE
            CFACE(ICF)%ONE_D%RDN = 0.5_EB/CUT_FACE(ICF1)%INT_XN(1,ICF2)
         ENDIF
      ENDDO
   ENDDO MESH_LOOP_3

ENDIF

RETURN
END SUBROUTINE SET_CFACES_ONE_D_RDN

END SUBROUTINE CCIBM_SET_DATA

! ------------------------------- CCIBM_END_STEP --------------------------------

SUBROUTINE CCIBM_END_STEP(T,DT,DIAGNOSTICS)

REAL(EB),INTENT(IN) :: T,DT
LOGICAL, INTENT(IN) :: DIAGNOSTICS

! Local Variables:
REAL(EB):: TNOW, PRFCT, VCELL, RHO_CC, TMP_CC, RSUM_CC, D_CC, ZZ_CC(1:N_TOTAL_SCALARS), VOL, VOLR
TYPE (OMESH_TYPE), POINTER :: OM
INTEGER :: NM,NOM,NN,ICC,JCC,IW,IIO,JJO,KKO
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC
LOGICAL :: DUMLOG
REAL(EB):: TNOW2

IF (FREEZE_VELOCITY .OR. SOLID_PHASE_ONLY) RETURN

TNOW = CURRENT_TIME()
TNOW2= TNOW

! Flux match Cartesian face velocity back to cut-faces:
CALL CCIBM_VELOCITY_CUTFACES

! Here inject OMESH cut-cell info obtained in MESH_CC_EXCHANGE into ghost-cell cc containers:
IF (PREDICTOR) PRFCT = 1._EB
IF (CORRECTOR) PRFCT = 0._EB
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE MESH_LOOP
   CALL POINT_TO_MESH(NM)
   EXTERNAL_WALL_LOOP : DO IW=1,N_EXTERNAL_WALL_CELLS
      WC=>WALL(IW)
      IF (.NOT.(WC%BOUNDARY_TYPE == INTERPOLATED_BOUNDARY)) CYCLE EXTERNAL_WALL_LOOP
      EWC=>EXTERNAL_WALL(IW)
      IF (CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_CGSC) /= IBM_CUTCFE) CYCLE EXTERNAL_WALL_LOOP
      ! Do volume average to a cell container for ghost cell II,JJ,KK:
      NOM = EWC%NOM
      OM  => MESHES(NM)%OMESH(NOM)
      RHO_CC = 0._EB; TMP_CC = 0._EB; RSUM_CC = 0._EB; D_CC = 0._EB; ZZ_CC(1:N_TOTAL_SCALARS) = 0._EB; VOL = 0._EB; VOLR = 0._EB
      DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
         DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
            DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
              ICC   = MESHES(NOM)%CCVAR(IIO,JJO,KKO,IBM_IDCC)
              IF (ICC > 0) THEN ! Cut-cells:
                 DO JCC=1,MESHES(NOM)%CUT_CELL(ICC)%NCELL
                    VCELL = MESHES(NOM)%CUT_CELL(ICC)%VOLUME(JCC)
                    RHO_CC  = RHO_CC  + (       PRFCT *MESHES(NOM)%CUT_CELL(ICC)%RHOS(JCC) &
                                      +  (1._EB-PRFCT)*MESHES(NOM)%CUT_CELL(ICC)%RHO(JCC) )*VCELL
                    TMP_CC  = TMP_CC  + MESHES(NOM)%CUT_CELL(ICC)%TMP(JCC)*VCELL
                    RSUM_CC = RSUM_CC + MESHES(NOM)%CUT_CELL(ICC)%RSUM(JCC)*VCELL
                    D_CC    = D_CC    + (       PRFCT *MESHES(NOM)%CUT_CELL(ICC)%D(JCC) &
                                      +  (1._EB-PRFCT)*MESHES(NOM)%CUT_CELL(ICC)%DS(JCC) )*VCELL
                    DO NN=1,N_TOTAL_SCALARS
                       ZZ_CC(NN) = ZZ_CC(NN) + (       PRFCT *MESHES(NOM)%CUT_CELL(ICC)%ZZS(NN,JCC) &
                                             +  (1._EB-PRFCT)*MESHES(NOM)%CUT_CELL(ICC)%ZZ(NN,JCC) )*VCELL
                    ENDDO
                    VOL     = VOL  + VCELL
                    VOLR    = VOLR + VCELL
                 ENDDO
              ELSEIF(MESHES(NOM)%CCVAR(IIO,JJO,KKO,IBM_CGSC) == IBM_GASPHASE) THEN ! Regular cell:
                 VCELL = MESHES(NOM)%DX(IIO)*MESHES(NOM)%DY(JJO)*MESHES(NOM)%DZ(KKO)
                 RHO_CC  = RHO_CC  + (        PRFCT*RHOS(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK) + &
                                      (1._EB-PRFCT)*RHO(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK))*VCELL
                 TMP_CC  = TMP_CC  + TMP(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK)*VCELL
                 !RSUM_CC = RSUM_CC + RSUM(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK)*VCELL
                 D_CC    = D_CC    + (        PRFCT*D(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK) + &
                                      (1._EB-PRFCT)*DS(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK))*VCELL
                 DO NN=1,N_TOTAL_SCALARS
                    ZZ_CC(NN) = ZZ_CC(NN) + (       PRFCT *ZZS(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,NN) &
                                          +  (1._EB-PRFCT)*ZZ(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,NN) )*VCELL
                 ENDDO
                 VOL     = VOL + VCELL
              ENDIF
            ENDDO
         ENDDO
      ENDDO
      ! Add volume averaged variables into ghost cut-cell:
      ICC   = CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_IDCC)
      IF (PREDICTOR) THEN
         DO JCC=1,CUT_CELL(ICC)%NCELL
            CUT_CELL(ICC)%RHOS(JCC) = RHO_CC/VOL
            CUT_CELL(ICC)%TMP(JCC)  = TMP_CC/VOL
            CUT_CELL(ICC)%RSUM(JCC) = RSUM_CC/VOLR
            CUT_CELL(ICC)%D(JCC)    = D_CC/VOL
            DO NN=1,N_TOTAL_SCALARS
               CUT_CELL(ICC)%ZZS(NN,JCC) = ZZ_CC(NN)/VOL
            ENDDO
         ENDDO
      ELSE
         DO JCC=1,CUT_CELL(ICC)%NCELL
            CUT_CELL(ICC)%RHO(JCC) = RHO_CC/VOL
            CUT_CELL(ICC)%TMP(JCC)  = TMP_CC/VOL
            !CUT_CELL(ICC)%RSUM(JCC) = RSUM_CC/VOL
            CUT_CELL(ICC)%DS(JCC)    = D_CC/VOL
            DO NN=1,N_TOTAL_SCALARS
               CUT_CELL(ICC)%ZZ(NN,JCC) = ZZ_CC(NN)/VOL
            ENDDO
         ENDDO
     ENDIF
   ENDDO EXTERNAL_WALL_LOOP
ENDDO MESH_LOOP


IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
   DUMLOG = DIAGNOSTICS
   IF (PREDICTOR) CALL CCIBM_CHECK_DIVERGENCE(T,DT,.TRUE.)
   IF (CORRECTOR) CALL CCIBM_CHECK_DIVERGENCE(T,DT,.FALSE.)
ELSE
   IF (CORRECTOR .AND. DIAGNOSTICS) CALL CCIBM_CHECK_DIVERGENCE(T,DT,.FALSE.)
ENDIF

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(CCIBM_END_STEP_TIME_INDEX) = T_CC_USED(CCIBM_END_STEP_TIME_INDEX) + CURRENT_TIME() - TNOW2
RETURN

END SUBROUTINE CCIBM_END_STEP

! ----------------------------- INIT_CUTCELL_DATA -------------------------------

SUBROUTINE INIT_CUTCELL_DATA(T,DT)

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT

REAL(EB), INTENT(IN) :: T, DT

! Local Variables:
INTEGER :: NM,I,J,K,N,ICC,JCC,X1AXIS,NFACE,ICF,IFACE
REAL(EB) TMP_CC,RHO_CC,AREAT,VEL_CF,RHOPV(-1:0)
REAL(EB), ALLOCATABLE, DIMENSION(:) :: ZZ_CC
TYPE(CFACE_TYPE), POINTER :: CFA=>NULL()
INTEGER :: INDADD, INDF, IFC, IFACE2, ICFC
REAL(EB):: FSCU, AREATOT

REAL(EB) :: TNOW

TNOW = CURRENT_TIME()

ALLOCATE( ZZ_CC(1:N_TOTAL_SCALARS) )

! Loop Meshes:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   ! Default initialization:
   ! Cut-cells inherit underlying Cartesian cell values of rho,T,Z, etc.:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH+MESHES(NM)%N_GCCUTCELL_MESH


      I = CUT_CELL(ICC)%IJK(IAXIS)
      J = CUT_CELL(ICC)%IJK(JAXIS)
      K = CUT_CELL(ICC)%IJK(KAXIS)

      IF (I < 0 .OR. I > IBP1) CYCLE
      IF (J < 0 .OR. J > JBP1) CYCLE
      IF (K < 0 .OR. K > KBP1) CYCLE

      TMP_CC = TMP(I,J,K)
      RHO_CC = RHO(I,J,K)
      ZZ_CC(1:N_TOTAL_SCALARS) = ZZ(I,J,K,1:N_TOTAL_SCALARS)

      DO JCC=1,CUT_CELL(ICC)%NCELL
         CUT_CELL(ICC)%TMP(JCC) = TMP_CC
         CUT_CELL(ICC)%RHO(JCC) = RHO_CC
         CUT_CELL(ICC)%RHOS(JCC)= RHO_CC
         CUT_CELL(ICC)%ZZ(1:N_TOTAL_SCALARS,JCC) = ZZ_CC(1:N_TOTAL_SCALARS)
         DO N=1,N_TRACKED_SPECIES
            CUT_CELL(ICC)%ZZS(N,JCC) = SPECIES_MIXTURE(N)%ZZ0
         ENDDO
         CUT_CELL(ICC)%MIX_TIME(JCC) = DT
         CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_CC(1:N_TRACKED_SPECIES),CUT_CELL(ICC)%RSUM(JCC))
         CUT_CELL(ICC)%D(JCC)        = 0._EB
         CUT_CELL(ICC)%DS(JCC)       = 0._EB
         CUT_CELL(ICC)%DVOL(JCC)     = 0._EB
         CUT_CELL(ICC)%D_SOURCE(JCC) = 0._EB
         CUT_CELL(ICC)%Q(JCC)        = 0._EB
         CUT_CELL(ICC)%QR(JCC)       = 0._EB
         CUT_CELL(ICC)%M_DOT_PPP(:,JCC) = 0._EB
      ENDDO
   ENDDO

   ! Gasphase Cut-faces inherit underlying Cartesian face values of Velocity (flux matched):
   PERIODIC_TEST_COND : IF (PERIODIC_TEST /= 21 .AND. PERIODIC_TEST /= 22) THEN

      ! First GASPHASe cut-faces:
      CUTFACE_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
         NFACE  = CUT_FACE(ICF)%NFACE
         IF (CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE
         I      = CUT_FACE(ICF)%IJK(IAXIS)
         J      = CUT_FACE(ICF)%IJK(JAXIS)
         K      = CUT_FACE(ICF)%IJK(KAXIS)
         X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

         AREAT  = SUM( CUT_FACE(ICF)%AREA(1:NFACE) )

         ! Flux matched U0 to cut-face centroids, they all get same velocity:
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            VEL_CF = (DY(J)*DZ(K))/AREAT * U(I,J,K)
         CASE(JAXIS)
            VEL_CF = (DX(I)*DZ(K))/AREAT * V(I,J,K)
         CASE(KAXIS)
            VEL_CF = (DX(I)*DY(J))/AREAT * W(I,J,K)
         END SELECT

         CUT_FACE(ICF)%VEL(1:NFACE)  = VEL_CF
         CUT_FACE(ICF)%VELS(1:NFACE) = VEL_CF
      ENDDO CUTFACE_LOOP

      ! Then INBOUNDARY cut-faces:
      ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         FSCU = 0._EB

         ! Loop on cells neighbors and test if they are of type IBM_SOLID, if so
         ! Add to velocity flux:
         ! X faces
         DO INDADD=-1,1,2
            INDF = I - 1 + (INDADD+1)/2
            IF( FCVAR(INDF,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID) CYCLE
            FSCU = FSCU + REAL(INDADD,EB)*U(INDF,J,K)*DY(J)*DZ(K)
         ENDDO
         ! Y faces
         DO INDADD=-1,1,2
            INDF = J - 1 + (INDADD+1)/2
            IF( FCVAR(I,INDF,K,IBM_FGSC,JAXIS) /= IBM_SOLID ) CYCLE
            FSCU = FSCU + REAL(INDADD,EB)*V(I,INDF,K)*DX(I)*DZ(K)
         ENDDO
         ! Z faces
         DO INDADD=-1,1,2
            INDF = K - 1 + (INDADD+1)/2
            IF( FCVAR(I,J,INDF,IBM_FGSC,KAXIS) /= IBM_SOLID ) CYCLE
            FSCU = FSCU + REAL(INDADD,EB)*W(I,J,INDF)*DX(I)*DY(J)
         ENDDO

         ! Now Define total area of INBOUNDARY cut-faces:
         ICF=CCVAR(I,J,K,IBM_IDCF);
         ICF_COND : IF (ICF > 0) THEN
            NFACE = CUT_FACE(ICF)%NFACE
            AREATOT = SUM ( CUT_FACE(ICF)%AREA(1:NFACE) )
            DO JCC =1,CUT_CELL(ICC)%NCELL
               IFC_LOOP : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
                  IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
                  IF (CUT_CELL(ICC)%FACE_LIST(1,IFACE) == IBM_FTYPE_CFINB) THEN
                     IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
                     ICFC    = CUT_FACE(ICF)%CFACE_INDEX(IFACE2)
                     IF(PRES_ON_WHOLE_DOMAIN) THEN
                        CUT_FACE(ICF)%VELS(IFACE2)  = 1._EB/AREATOT*FSCU ! +ve into the solid Velocity error
                        CUT_FACE(ICF)%VEL( IFACE2)  = 1._EB/AREATOT*FSCU
                     ELSE
                        CUT_FACE(ICF)%VELS(IFACE2)  = 0._EB
                        CUT_FACE(ICF)%VEL( IFACE2)  = 0._EB
                     ENDIF
                  ENDIF
               ENDDO IFC_LOOP
            ENDDO
         ENDIF ICF_COND
      ENDDO ICC_LOOP

   ENDIF PERIODIC_TEST_COND

   ! Populate PHOPVN in regular faces of CCIMPREGION:
   ! IAXIS faces:
   X1AXIS = IAXIS
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)

      I  = MESHES(NM)%IBM_REGFACE_IAXIS_Z(IFACE)%IJK(IAXIS)
      J  = MESHES(NM)%IBM_REGFACE_IAXIS_Z(IFACE)%IJK(JAXIS)
      K  = MESHES(NM)%IBM_REGFACE_IAXIS_Z(IFACE)%IJK(KAXIS)

      MESHES(NM)%IBM_REGFACE_IAXIS_Z(IFACE)%RHOPVN(-1:0) = RHO(I:I+1,J,K)

   ENDDO

   ! JAXIS faces:
   X1AXIS = JAXIS
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)

      I  = MESHES(NM)%IBM_REGFACE_JAXIS_Z(IFACE)%IJK(IAXIS)
      J  = MESHES(NM)%IBM_REGFACE_JAXIS_Z(IFACE)%IJK(JAXIS)
      K  = MESHES(NM)%IBM_REGFACE_JAXIS_Z(IFACE)%IJK(KAXIS)

      MESHES(NM)%IBM_REGFACE_JAXIS_Z(IFACE)%RHOPVN(-1:0) = RHO(I,J:J+1,K)

   ENDDO

   ! KAXIS faces:
   X1AXIS = KAXIS
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)

      I  = MESHES(NM)%IBM_REGFACE_KAXIS_Z(IFACE)%IJK(IAXIS)
      J  = MESHES(NM)%IBM_REGFACE_KAXIS_Z(IFACE)%IJK(JAXIS)
      K  = MESHES(NM)%IBM_REGFACE_KAXIS_Z(IFACE)%IJK(KAXIS)

      MESHES(NM)%IBM_REGFACE_KAXIS_Z(IFACE)%RHOPVN(-1:0) = RHO(I,J,K:K+1)

   ENDDO

   ! Now populate RCFACES:
   DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z

      I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
      J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
      K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
      X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)

      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            RHOPV(-1:0) = RHO(I:I+1,J,K)
         CASE(JAXIS)
            RHOPV(-1:0) = RHO(I,J:J+1,K)
         CASE(KAXIS)
            RHOPV(-1:0) = RHO(I,J,K:K+1)
      ENDSELECT

      IBM_RCFACE_Z(IFACE)%RHOPVN(-1:0) = RHOPV(-1:0)
   ENDDO

   ! Finally Cut-faces:
   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE

      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            RHOPV(-1:0) = RHO(I:I+1,J,K)
         CASE(JAXIS)
            RHOPV(-1:0) = RHO(I,J:J+1,K)
         CASE(KAXIS)
            RHOPV(-1:0) = RHO(I,J,K:K+1)
      ENDSELECT

      DO IFACE=1,CUT_FACE(ICF)%NFACE
         CUT_FACE(ICF)%RHOPVN(-1:0,IFACE) = RHOPV(-1:0)
      ENDDO
   ENDDO

   ! CFACES initialize ONE_D BCs:
   DO ICF=1,N_CFACE_CELLS
      CFA  => CFACE(ICF)
      CALL INIT_CFACE_CELL(NM,CFA%CUT_FACE_IND1,CFA%CUT_FACE_IND2,ICF,CFA%SURF_INDEX,INTEGER_THREE)
   ENDDO


ENDDO MESH_LOOP

DEALLOCATE( ZZ_CC )

CALL MESH_CC_EXCHANGE(1)
CALL MESH_CC_EXCHANGE(4)
CALL MESH_CC_EXCHANGE(6)

CALL CCIBM_H_INTERP
CALL CCIBM_RHO0W_INTERP

! Check divergence of initial velocity field:
IF(GET_CUTCELLS_VERBOSE) CALL CCIBM_CHECK_DIVERGENCE(T,DT,.FALSE.)

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(INIT_CUTCELL_DATA_TIME_INDEX) = T_CC_USED(INIT_CUTCELL_DATA_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE INIT_CUTCELL_DATA

! ---------------------------- CCIBM_VELOCITY_NO_GRADH -----------------------------

SUBROUTINE CCIBM_VELOCITY_NO_GRADH(DT,STORE_UN)

REAL(EB), INTENT(IN) :: DT
LOGICAL, INTENT(IN)  :: STORE_UN

! Local Variables:
INTEGER :: I,J,K
INTEGER, SAVE :: N_SC_FACES
REAL(EB), SAVE, ALLOCATABLE, DIMENSION(:) :: UN_SOLID

! Here return if PRES_ON_WHOLE_DOMAIN=.TRUE., i.e. 'FFT' or 'GLMAT', etc. solvers are defined at input.
IF (.NOT.PRES_ON_CARTESIAN .OR. PRES_ON_WHOLE_DOMAIN) RETURN

PREDICTOR_COND : IF (PREDICTOR) THEN

   DO K=1,KBAR
      DO J=1,JBAR
         DO I=0,IBAR
            IF (FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID) CYCLE
            US(I,J,K) = U(I,J,K) - DT*( FVX(I,J,K) )
         ENDDO
      ENDDO
   ENDDO

   DO K=1,KBAR
      DO J=0,JBAR
         DO I=1,IBAR
            IF (FCVAR(I,J,K,IBM_FGSC,JAXIS) /= IBM_SOLID) CYCLE
            VS(I,J,K) = V(I,J,K) - DT*( FVY(I,J,K) )
         ENDDO
      ENDDO
   ENDDO

   DO K=0,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_SOLID) CYCLE
            WS(I,J,K) = W(I,J,K) - DT*( FVZ(I,J,K) )
         ENDDO
      ENDDO
   ENDDO

ELSE ! Corrector

   STORE_COND : IF (STORE_UN) THEN

      N_SC_FACES=0
      ! X axis:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=0,IBAR
               IF (FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID) CYCLE
               N_SC_FACES = N_SC_FACES + 1
            ENDDO
         ENDDO
      ENDDO
      ! Y axis:
      DO K=1,KBAR
         DO J=0,JBAR
            DO I=1,IBAR
               IF (FCVAR(I,J,K,IBM_FGSC,JAXIS) /= IBM_SOLID) CYCLE
               N_SC_FACES = N_SC_FACES + 1
            ENDDO
         ENDDO
      ENDDO
      ! Z axis:
      DO K=0,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_SOLID) CYCLE
               N_SC_FACES = N_SC_FACES + 1
            ENDDO
         ENDDO
      ENDDO

      IF(ALLOCATED(UN_SOLID)) DEALLOCATE(UN_SOLID)
      ALLOCATE( UN_SOLID(1:N_SC_FACES) )
      UN_SOLID(:) = 0._EB

      N_SC_FACES=0
      ! X axis:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=0,IBAR
               IF (FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID) CYCLE
               N_SC_FACES = N_SC_FACES + 1
               UN_SOLID(N_SC_FACES) = U(I,J,K)
            ENDDO
         ENDDO
      ENDDO
      ! Y axis:
      DO K=1,KBAR
         DO J=0,JBAR
            DO I=1,IBAR
               IF (FCVAR(I,J,K,IBM_FGSC,JAXIS) /= IBM_SOLID) CYCLE
               N_SC_FACES = N_SC_FACES + 1
               UN_SOLID(N_SC_FACES) = V(I,J,K)
            ENDDO
         ENDDO
      ENDDO
      ! Z axis:
      DO K=0,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_SOLID) CYCLE
               N_SC_FACES = N_SC_FACES + 1
               UN_SOLID(N_SC_FACES) = W(I,J,K)
            ENDDO
         ENDDO
      ENDDO

      RETURN

   ENDIF STORE_COND

   N_SC_FACES=0
   ! X axis:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=0,IBAR
            IF (FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID) CYCLE
            N_SC_FACES = N_SC_FACES + 1
            U(I,J,K) = 0.5_EB*( UN_SOLID(N_SC_FACES) + US(I,J,K) - DT*FVX(I,J,K) )
         ENDDO
      ENDDO
   ENDDO
   ! Y axis:
   DO K=1,KBAR
      DO J=0,JBAR
         DO I=1,IBAR
            IF (FCVAR(I,J,K,IBM_FGSC,JAXIS) /= IBM_SOLID) CYCLE
            N_SC_FACES = N_SC_FACES + 1
            V(I,J,K) = 0.5_EB*( UN_SOLID(N_SC_FACES) + VS(I,J,K) - DT*FVY(I,J,K) )
         ENDDO
      ENDDO
   ENDDO
   ! Z axis:
   DO K=0,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_SOLID) CYCLE
            N_SC_FACES = N_SC_FACES + 1
            W(I,J,K) = 0.5_EB*( UN_SOLID(N_SC_FACES) + WS(I,J,K) - DT*FVZ(I,J,K) )
         ENDDO
      ENDDO
   ENDDO

   DEALLOCATE(UN_SOLID)

ENDIF PREDICTOR_COND


RETURN
END SUBROUTINE CCIBM_VELOCITY_NO_GRADH

! ------------------------------- SET_EXIMADVFLX_3D ------------------------------

SUBROUTINE SET_EXIMADVFLX_3D(NM,UU,VV,WW)

INTEGER, INTENT(IN) :: NM
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU,VV,WW

! Local Variables:
INTEGER :: N,I,J,K,X1AXIS,IFACE
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()
! Loop on scalars:
SPECIES_LOOP : DO N=1,N_TOTAL_SCALARS

   AXIS_DO : DO X1AXIS = IAXIS,KAXIS
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         REGFACE_Z => IBM_REGFACE_IAXIS_Z
      CASE(JAXIS)
         REGFACE_Z => IBM_REGFACE_JAXIS_Z
      CASE(KAXIS)
         REGFACE_Z => IBM_REGFACE_KAXIS_Z
      END SELECT
      IFACE_DO : DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
         I  = REGFACE_Z(IFACE)%IJK(IAXIS)
         J  = REGFACE_Z(IFACE)%IJK(JAXIS)
         K  = REGFACE_Z(IFACE)%IJK(KAXIS)
         ! Load Advective flux in REG face container:
         REGFACE_Z(IFACE)%RHOZZ_U(N) = 0._EB
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            REGFACE_Z(IFACE)%RHOZZ_U(N) = FX(I,J,K,N)*UU(I,J,K)*R(I)
         CASE(JAXIS)
            REGFACE_Z(IFACE)%RHOZZ_U(N) = FY(I,J,K,N)*VV(I,J,K)
         CASE(KAXIS)
            REGFACE_Z(IFACE)%RHOZZ_U(N) = FZ(I,J,K,N)*WW(I,J,K)
         END SELECT
      ENDDO IFACE_DO
   ENDDO AXIS_DO

ENDDO SPECIES_LOOP

RETURN
END SUBROUTINE SET_EXIMADVFLX_3D

! ----------------------------- SET_EXIMRHOZZLIM_3D -----------------------------

SUBROUTINE SET_EXIMRHOZZLIM_3D(NM,N)

! Get flux limited \bar{rho Za} computed on divg.f90 in EXIM boundary faces.

INTEGER, INTENT(IN) :: NM, N

! Local Variables:
INTEGER :: I,J,K,X1AXIS
REAL(EB), POINTER, DIMENSION(:,:,:) :: FX_ZZ=>NULL(),FY_ZZ=>NULL(),FZ_ZZ=>NULL()
INTEGER :: IFACE,IW
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()

FX_ZZ=>WORK2
FY_ZZ=>WORK3
FZ_ZZ=>WORK4

AXIS_DO : DO X1AXIS = IAXIS,KAXIS
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      REGFACE_Z => IBM_REGFACE_IAXIS_Z
   CASE(JAXIS)
      REGFACE_Z => IBM_REGFACE_JAXIS_Z
   CASE(KAXIS)
      REGFACE_Z => IBM_REGFACE_KAXIS_Z
   END SELECT
   IFACE_DO : DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE IFACE_DO
      I  = REGFACE_Z(IFACE)%IJK(IAXIS)
      J  = REGFACE_Z(IFACE)%IJK(JAXIS)
      K  = REGFACE_Z(IFACE)%IJK(KAXIS)
      ! Load Diffusive flux in EXIM boundary face container:
      REGFACE_Z(IFACE)%FN_ZZ(N) = 0._EB
      IF (REGFACE_Z(IFACE)%IWC > 0) THEN
         WC=>WALL(REGFACE_Z(IFACE)%IWC)
         IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE
         REGFACE_Z(IFACE)%FN_ZZ(N)=WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
      ELSE
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            REGFACE_Z(IFACE)%FN_ZZ(N) = FX_ZZ(I,J,K)
         CASE(JAXIS)
            REGFACE_Z(IFACE)%FN_ZZ(N) = FY_ZZ(I,J,K)
         CASE(KAXIS)
            REGFACE_Z(IFACE)%FN_ZZ(N) = FZ_ZZ(I,J,K)
         END SELECT
      ENDIF
   ENDDO IFACE_DO
ENDDO AXIS_DO

RETURN
END SUBROUTINE SET_EXIMRHOZZLIM_3D

! ----------------------------- SET_EXIMRHOHSLIM_3D -----------------------------

SUBROUTINE SET_EXIMRHOHSLIM_3D(NM)

! Get flux limited \bar{rho hs} computed on divg.f90 in EXIM boundary faces.

USE PHYSICAL_FUNCTIONS, ONLY: GET_SENSIBLE_ENTHALPY

INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER :: I,J,K,X1AXIS
REAL(EB), POINTER, DIMENSION(:,:,:) :: FX_H_S=>NULL(),FY_H_S=>NULL(),FZ_H_S=>NULL()
REAL(EB) :: H_S,ZZ_GET(1:N_TRACKED_SPECIES),TMP_F_GAS,VELC2
INTEGER :: IFACE,IW
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()

FX_H_S=>WORK2
FY_H_S=>WORK3
FZ_H_S=>WORK4

AXIS_DO : DO X1AXIS = IAXIS,KAXIS
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      REGFACE_Z => IBM_REGFACE_IAXIS_Z
   CASE(JAXIS)
      REGFACE_Z => IBM_REGFACE_JAXIS_Z
   CASE(KAXIS)
      REGFACE_Z => IBM_REGFACE_KAXIS_Z
   END SELECT
   IFACE_DO : DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE IFACE_DO
      I  = REGFACE_Z(IFACE)%IJK(IAXIS)
      J  = REGFACE_Z(IFACE)%IJK(JAXIS)
      K  = REGFACE_Z(IFACE)%IJK(KAXIS)
      ! Load Diffusive flux in REG boundary face container:
      REGFACE_Z(IFACE)%FN_H_S = 0._EB
      IF (REGFACE_Z(IFACE)%IWC > 0) THEN
         IW = REGFACE_Z(IFACE)%IWC
         WC=>WALL(IW)
         IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY) CYCLE IFACE_DO
         IF (PREDICTOR) THEN
            VELC2 = WC%ONE_D%U_NORMAL_S
         ELSE
            VELC2 = WC%ONE_D%U_NORMAL
         ENDIF
         IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY .AND. VELC2>0._EB) THEN
            TMP_F_GAS = WC%ONE_D%TMP_G
         ELSE
            TMP_F_GAS = WC%ONE_D%TMP_F
         ENDIF
         ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
         CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
         REGFACE_Z(IFACE)%FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
      ELSE
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            REGFACE_Z(IFACE)%FN_H_S = FX_H_S(I,J,K)
         CASE(JAXIS)
            REGFACE_Z(IFACE)%FN_H_S = FY_H_S(I,J,K)
         CASE(KAXIS)
            REGFACE_Z(IFACE)%FN_H_S = FZ_H_S(I,J,K)
         END SELECT
      ENDIF
   ENDDO IFACE_DO
ENDDO AXIS_DO

RETURN
END SUBROUTINE SET_EXIMRHOHSLIM_3D

! ------------------------------ SET_EXIMDIFFLX_3D ------------------------------

SUBROUTINE SET_EXIMDIFFLX_3D(NM,RHO_D_DZDX,RHO_D_DZDY,RHO_D_DZDZ)

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN), POINTER, DIMENSION(:,:,:,:) :: RHO_D_DZDX,RHO_D_DZDY,RHO_D_DZDZ

! Local Variables:
INTEGER :: N,I,J,K,X1AXIS,IFACE
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()

! First, set all diffusive fluxes to zero on IBM_SOLID faces:
! IAXIS:
X1AXIS = IAXIS
DO K=1,MESHES(NM)%KBAR
   DO J=1,MESHES(NM)%JBAR
      DO I=0,MESHES(NM)%IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,X1AXIS) /= IBM_SOLID ) CYCLE
         RHO_D_DZDX(I,J,K,1:N_TOTAL_SCALARS) = 0._EB
      ENDDO
   ENDDO
ENDDO
! JAXIS:
X1AXIS = JAXIS
DO K=1,MESHES(NM)%KBAR
   DO J=0,MESHES(NM)%JBAR
      DO I=1,MESHES(NM)%IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,X1AXIS) /= IBM_SOLID ) CYCLE
         RHO_D_DZDY(I,J,K,1:N_TOTAL_SCALARS) = 0._EB
      ENDDO
   ENDDO
ENDDO
! KAXIS:
X1AXIS = KAXIS
DO K=0,MESHES(NM)%KBAR
   DO J=1,MESHES(NM)%JBAR
      DO I=1,MESHES(NM)%IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,X1AXIS) /= IBM_SOLID ) CYCLE
         RHO_D_DZDZ(I,J,K,1:N_TOTAL_SCALARS) = 0._EB
      ENDDO
   ENDDO
ENDDO

! Loop on scalars:
SPECIES_LOOP : DO N=1,N_TOTAL_SCALARS

   AXIS_DO : DO X1AXIS = IAXIS,KAXIS
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         REGFACE_Z => IBM_REGFACE_IAXIS_Z
      CASE(JAXIS)
         REGFACE_Z => IBM_REGFACE_JAXIS_Z
      CASE(KAXIS)
         REGFACE_Z => IBM_REGFACE_KAXIS_Z
      END SELECT
      IFACE_DO : DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
         I  = REGFACE_Z(IFACE)%IJK(IAXIS)
         J  = REGFACE_Z(IFACE)%IJK(JAXIS)
         K  = REGFACE_Z(IFACE)%IJK(KAXIS)
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            REGFACE_Z(IFACE)%RHO_D_DZDN(N) = RHO_D_DZDX(I,J,K,N)
         CASE(JAXIS)
            REGFACE_Z(IFACE)%RHO_D_DZDN(N) = RHO_D_DZDY(I,J,K,N)
         CASE(KAXIS)
            REGFACE_Z(IFACE)%RHO_D_DZDN(N) = RHO_D_DZDZ(I,J,K,N)
         END SELECT
      ENDDO IFACE_DO
   ENDDO AXIS_DO

ENDDO SPECIES_LOOP

RETURN
END SUBROUTINE SET_EXIMDIFFLX_3D


! -------------------------------- FINISH_CCIBM ---------------------------------

SUBROUTINE FINISH_CCIBM

USE MPI_F08

! Local variables:
INTEGER :: I, TLB, TUB, LU_TCC, IERR
CHARACTER(MESSAGE_LENGTH) :: CC_CPU_FILE
REAL(EB), ALLOCATABLE, DIMENSION(:) :: T_CC_USED_MIN, T_CC_USED_MAX, T_CC_USED_MEA
CHARACTER(30) :: FRMT

IF (TIME_CC_IBM) THEN
   TLB = LBOUND(T_CC_USED,DIM=1)
   TUB = UBOUND(T_CC_USED,DIM=1)
   ALLOCATE(T_CC_USED_MIN(TLB:TUB),T_CC_USED_MAX(TLB:TUB),T_CC_USED_MEA(TLB:TUB))
   IF (N_MPI_PROCESSES > 1) THEN
      CALL MPI_ALLREDUCE(T_CC_USED(TLB) , T_CC_USED_MIN(TLB) , TUB-TLB+1, MPI_DOUBLE_PRECISION, MPI_MIN, MPI_COMM_WORLD, IERR)
      CALL MPI_ALLREDUCE(T_CC_USED(TLB) , T_CC_USED_MAX(TLB) , TUB-TLB+1, MPI_DOUBLE_PRECISION, MPI_MAX, MPI_COMM_WORLD, IERR)
      CALL MPI_ALLREDUCE(T_CC_USED(TLB) , T_CC_USED_MEA(TLB) , TUB-TLB+1, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, IERR)
      T_CC_USED_MEA = T_CC_USED_MEA / REAL(N_MPI_PROCESSES,EB)
   ELSE
      T_CC_USED_MIN(TLB:TUB) = T_CC_USED(TLB:TUB)
      T_CC_USED_MAX(TLB:TUB) = T_CC_USED(TLB:TUB)
      T_CC_USED_MEA(TLB:TUB) = T_CC_USED(TLB:TUB)
   ENDIF
   IF (MY_RANK==0) THEN
      WRITE(CC_CPU_FILE,'(A,A)') TRIM(CHID),'_cc_cpu.csv'
      OPEN(NEWUNIT=LU_TCC,FILE=TRIM(CC_CPU_FILE),STATUS='UNKNOWN')
      WRITE(LU_TCC,'(A,A,A)') 'CCCOMPUTE_RADIATION, CCREGION_DENSITY, CCIBM_VELOCITY_FLUX, CCREGION_COMPUTE_VISCOSITY, ',&
                              'CCIBM_INTERP_FACE_VEL, CCREGION_DIVERGENCE_PART_1, CCIBM_END_STEP, CCIBM_TARGET_VELOCITY, ',&
                              'CCIBM_NO_FLUX, CCIBM_COMPUTE_VELOCITY_ERROR, MESH_CC_EXCHANGE (s)'
      WRITE(FRMT,'(A,I2.2,A)') '(',MESH_CC_EXCHANGE_TIME_INDEX-CCCOMPUTE_RADIATION_TIME_INDEX+1,'(",",ES10.3))'
      WRITE(LU_TCC,FRMT) (T_CC_USED_MIN(I),I=CCCOMPUTE_RADIATION_TIME_INDEX,MESH_CC_EXCHANGE_TIME_INDEX)
      WRITE(LU_TCC,FRMT) (T_CC_USED_MAX(I),I=CCCOMPUTE_RADIATION_TIME_INDEX,MESH_CC_EXCHANGE_TIME_INDEX)
      WRITE(LU_TCC,FRMT) (T_CC_USED_MEA(I),I=CCCOMPUTE_RADIATION_TIME_INDEX,MESH_CC_EXCHANGE_TIME_INDEX)
      CLOSE(LU_TCC)
   ENDIF
   DEALLOCATE(T_CC_USED_MIN,T_CC_USED_MAX,T_CC_USED_MEA)
ENDIF

! Release Requests:
DO I=1,N_REQ11  ; CALL MPI_REQUEST_FREE(REQ11(I) ,IERR) ; ENDDO
DO I=1,N_REQ12  ; CALL MPI_REQUEST_FREE(REQ12(I) ,IERR) ; ENDDO
DO I=1,N_REQ13  ; CALL MPI_REQUEST_FREE(REQ13(I) ,IERR) ; ENDDO

RETURN
END SUBROUTINE FINISH_CCIBM


! -------------------------- CCREGION_DIVERGENCE_PART_1 --------------------------

SUBROUTINE CCREGION_DIVERGENCE_PART_1(T,DT,NM)

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_HEAT,GET_SENSIBLE_ENTHALPY_Z, &
                              GET_SENSIBLE_ENTHALPY,GET_VISCOSITY,GET_MOLECULAR_WEIGHT
USE MANUFACTURED_SOLUTIONS, ONLY: UF_MMS,WF_MMS,VD2D_MMS_Z_SRC

REAL(EB), INTENT(IN) :: T,DT
INTEGER,  INTENT(IN) :: NM
! Recompute divergence terms in cut-cell region and surrounding cells.
! Use velocity divergence equivalence to define divergence on cut-cell underlying Cartesian cells.

! Local Variables:
INTEGER :: N,I,J,K,X1AXIS,ISIDE,IFACE,ICC,JCC,ICF
REAL(EB), POINTER, DIMENSION(:,:,:) :: DP,DPVOL,RHOP,RTRM,CP,R_H_G,U_DOT_DEL_RHO_Z_VOL
REAL(EB), POINTER, DIMENSION(:,:) :: PBAR_P
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP
REAL(EB) :: RDT,CCM1,CCP1,IDX,AF,TMP_G,H_S,ZZ_FACE(MAX_SPECIES),TNOW,RHOPV(-1:0),TMPV(-1:0),X1F,PRFCT,PRFCTV, &
            CPV(-1:0),FCT,MUV(-1:0),MU_DNSV(-1:0)
REAL(EB), ALLOCATABLE, DIMENSION(:) :: ZZ_GET
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU,VV,WW
TYPE(SPECIES_MIXTURE_TYPE), POINTER :: SM

REAL(EB) :: VCELL, VCCELL, DIVVOL, MINVOL, DUMMY, RTRMVOL, DIVVOL_BC

LOGICAL, PARAMETER :: DO_CONDUCTION_HEAT_FLUX=.TRUE.
INTEGER :: DIFFHFLX_IND, JFLX_IND

LOGICAL, PARAMETER :: SET_DIV_TO_ZERO  = .FALSE.
LOGICAL, PARAMETER :: SET_CCDIV_TO_ZERO= .FALSE.
LOGICAL, PARAMETER :: AVERAGE_LINKDIV  = .TRUE.
LOGICAL, PARAMETER :: FIX_DIFF_FLUXES  = .TRUE.

REAL(EB), PARAMETER :: FLX_EPS=1.E-15_EB

REAL(EB), ALLOCATABLE, DIMENSION(:) :: DIVRG_VEC , RTRM_VEC, VOLDVRG
INTEGER :: INDZ

! Pressure sums re-integration vars:
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(CFACE_TYPE), POINTER :: CFA=>NULL()
INTEGER :: IW,IND1,IND2,JCF,ICFACE

! Shunn MMS test case vars:
REAL(EB) :: XHAT, ZHAT, Q_Z, TT

! Dummy on T:
DUMMY = T

! Check whether to skip this routine

IF (SOLID_PHASE_ONLY) RETURN

TNOW=CURRENT_TIME()

DIFFHFLX_IND = LOW_IND  ! -rho Da Grad(Za)
JFLX_IND     = LOW_IND

CALL POINT_TO_MESH(NM)

RDT = 1._EB/DT

SELECT CASE(PREDICTOR)
   CASE(.TRUE.)
      DP     => DS
      PBAR_P => PBAR_S
      RHOP   => RHOS
      PRFCT  = 0._EB ! Use star cut-cell quantities.
   CASE(.FALSE.)
      DP     => DDDT
      PBAR_P => PBAR
      RHOP   => RHO
      PRFCT  = 1._EB ! Use end of step cut-cell quantities.
END SELECT


R_PBAR = 1._EB/PBAR_P
DPVOL  => DP
RTRM   => WORK1

! Set DP to zero in Cartesian cells of type: IBM_SOLID, IBM_CUTCFE, and IBM_GASPHASE where IBM_UNKZ > 0:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF ((CCVAR(I,J,K,IBM_CGSC) == IBM_GASPHASE) .AND. (CCVAR(I,J,K,IBM_UNKZ) <= 0)) CYCLE
         DPVOL(I,J,K) = 0._EB
      ENDDO
   ENDDO
ENDDO
DO ICC=1,MESHES(NM)%N_CUTCELL_MESH+MESHES(NM)%N_GCCUTCELL_MESH
   CUT_CELL(ICC)%DVOL(1:CUT_CELL(ICC)%NCELL)= 0._EB
   CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,1:CUT_CELL(ICC)%NCELL)=0._EB
ENDDO
IF (CORRECTOR) THEN
   IF (N_LP_ARRAY_INDICES>0 .OR. N_REACTIONS>0 .OR. ANY(SPECIES_MIXTURE%DEPOSITING)) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I     = CUT_CELL(ICC)%IJK(IAXIS)
         J     = CUT_CELL(ICC)%IJK(JAXIS)
         K     = CUT_CELL(ICC)%IJK(KAXIS)
         VCELL = DX(I)*DY(J)*DZ(K)

         ! Up to here in D_SOURCE(I,J,K), M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) we have contributions by particles.
         ! Add these contributions in corresponding cut-cells:
         ! NOTE : Assumes the source from particles is distributed evely over CCs of the Cartesian cell.
         VCCELL = SUM(CUT_CELL(ICC)%VOLUME(1:CUT_CELL(ICC)%NCELL))
         DO JCC=1,CUT_CELL(ICC)%NCELL
            CUT_CELL(ICC)%D_SOURCE(JCC) = CUT_CELL(ICC)%D_SOURCE(JCC) + D_SOURCE(I,J,K)*VCELL/VCCELL
            CUT_CELL(ICC)%M_DOT_PPP(1:N_TOTAL_SCALARS,JCC) = CUT_CELL(ICC)%M_DOT_PPP(1:N_TOTAL_SCALARS,JCC) + &
            M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS)*VCELL/VCCELL
         ENDDO

         ! Now Add back to D_SOURCE(I,J,K), M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) for regular slice plotting:
         D_SOURCE(I,J,K) = 0._EB; M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) = 0._EB
         DO JCC=1,CUT_CELL(ICC)%NCELL
            D_SOURCE(I,J,K) = D_SOURCE(I,J,K) + CUT_CELL(ICC)%D_SOURCE(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) = M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) + &
            CUT_CELL(ICC)%M_DOT_PPP(1:N_TOTAL_SCALARS,JCC)*CUT_CELL(ICC)%VOLUME(JCC)
         ENDDO
         D_SOURCE(I,J,K)=D_SOURCE(I,J,K)/VCELL
         M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) = M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS)/VCELL
      ENDDO
   ENDIF
ENDIF

IF (SET_DIV_TO_ZERO) THEN
   DP = 0._EB ! Set to zero divg on all cells.
   RETURN
ENDIF
IF (SET_CCDIV_TO_ZERO) RETURN

! Point to corresponding ZZ array:
SELECT CASE(PREDICTOR)
   CASE(.TRUE.)
      ZZP => ZZS
   CASE(.FALSE.)
      ZZP => ZZ
END SELECT

ALLOCATE(ZZ_GET(N_TRACKED_SPECIES))

! Add species diffusion terms to divergence expression and compute diffusion term for species equations
SPECIES_GT_1_IF: IF (N_TOTAL_SCALARS>1) THEN

   ! 1. Diffusive Heat flux = - Grad dot (h_s rho D Grad Z_n):
   ! In FV form: use faces to add corresponding face integral terms, for face k
   ! (sum_a{h_{s,a} rho D_a Grad z_a) dot \hat{n}_k A_k, where \hat{n}_k is the versor outside of cell
   ! at face k.
   CALL CCREGION_DIFFUSIVE_MASS_FLUXES(NM)

   ! Ensure RHO_D terms sum to zero over all species.  Gather error into largest mass fraction present.
   IF (FIX_DIFF_FLUXES) CALL FIX_CCREGION_DIFF_MASS_FLUXES

   ! Zero out DEL_RHO_D_DEL_Z for impregion regular cells:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF(CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            DEL_RHO_D_DEL_Z(I,J,K,1:N_TOTAL_SCALARS) = 0._EB
         ENDDO
      ENDDO
   ENDDO

   ! 1. Diffusive heat flux  = - hs,a (Da Grad(rho*Ya) - Da/rho Grad(rho) (rho Ya)):
   CALL CCREGION_DIFFUSIVE_HEAT_FLUXES

ENDIF SPECIES_GT_1_IF


CONDUCTION_HEAT_IF : IF( DO_CONDUCTION_HEAT_FLUX ) THEN
   ! 2. Conduction heat flux = - k Grad(T):
   CALL CCREGION_CONDUCTION_HEAT_FLUX
ENDIF CONDUCTION_HEAT_IF


! Add \dot{q}''' and QR to DP:
! Regular cells:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
         ! Add \dot{q}''' and QR to DP*Vii:
         DPVOL(I,J,K) = DPVOL(I,J,K) + (Q(I,J,K) + QR(I,J,K)) * DX(I)*DY(J)*DZ(K)
      ENDDO
   ENDDO
ENDDO

! HERE Cut-cells \dot{q}'''*VOL and QR*VOL:
DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
   DO JCC=1,CUT_CELL(ICC)%NCELL
      CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC)+(CUT_CELL(ICC)%Q(JCC)+CUT_CELL(ICC)%QR(JCC))*CUT_CELL(ICC)%VOLUME(JCC)
   ENDDO
ENDDO

! 3. Enthalpy advection term = - \bar{ u dot Grad (rho h_s) }:
! R_H_G = 1/(Cp * T)
! RTRM  = 1/(rho * Cp * T)
! Point to the appropriate velocity components

IF (PREDICTOR) THEN
   UU=>U
   VV=>V
   WW=>W
   PRFCTV = 1._EB
ELSE
   UU=>US
   VV=>VS
   WW=>WS
   PRFCTV = 0._EB
ENDIF

CONST_GAMMA_IF_1: IF (.NOT.CONSTANT_SPECIFIC_HEAT_RATIO) THEN
   CALL CCENTHALPY_ADVECTION ! Compute u dot grad rho h_s in FV form and add to DP in regular + cut-cells.
ENDIF CONST_GAMMA_IF_1


! Loop through regular cells in the implicit region, as well as cut-cells and compute R_H_G, and RTRM:
CP    => WORK5
R_H_G => WORK9
RTRM  => WORK1
! Regular cells:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K,1:N_TRACKED_SPECIES)
         CALL GET_SPECIFIC_HEAT(ZZ_GET,CP(I,J,K),TMP(I,J,K))
         R_H_G(I,J,K) = 1._EB/(CP(I,J,K)*TMP(I,J,K))
         RTRM(I,J,K)  = R_H_G(I,J,K)/RHOP(I,J,K)
         DPVOL(I,J,K) = RTRM(I,J,K)*DPVOL(I,J,K)
      ENDDO
   ENDDO
ENDDO

! Cut-cells:
DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
   DO JCC=1,CUT_CELL(ICC)%NCELL
      TMPV(0) = CUT_CELL(ICC)%TMP(JCC)
      ZZ_GET(1:N_TRACKED_SPECIES) =  &
             PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
      (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
      CALL GET_SPECIFIC_HEAT(ZZ_GET,CPV(0),TMPV(0))
      CUT_CELL(ICC)%R_H_G(JCC) = 1._EB/(CPV(0)*TMPV(0))
      RHOPV(0) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
          (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
      CUT_CELL(ICC)%RTRM(JCC) = CUT_CELL(ICC)%R_H_G(JCC)/RHOPV(0)
      CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%RTRM(JCC)*CUT_CELL(ICC)%DVOL(JCC)
   ENDDO
ENDDO


! 4. Enthalpy flux due to mass diffusion and advection:
! sum_n [\bar{W}/W_n - h_{s,n}*R_H_G] ( Grad dot (rho D_\alpha Grad Z_n) - \bar{u dot Grad (rho Z_n)})

CONST_GAMMA_IF_2: IF (.NOT.CONSTANT_SPECIFIC_HEAT_RATIO) THEN

   SPECIES_LOOP: DO N=1,N_TRACKED_SPECIES

      CALL CCSPECIES_ADVECTION ! Compute u dot grad rho Z_n

      SM  => SPECIES_MIXTURE(N)

      ! Regular cells:
      ICC = 0
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
               CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP(I,J,K),H_S)
               DPVOL(I,J,K) = DPVOL(I,J,K) + (SM%RCON/RSUM(I,J,K) - H_S*R_H_G(I,J,K))* &
                                             (DEL_RHO_D_DEL_Z(I,J,K,N) - U_DOT_DEL_RHO_Z_VOL(I,J,K))/RHOP(I,J,K)
               ! Values of DEL_RHO_D_DEL_Z(I,J,K,N) have been filled previously.
               ! RSUM was computed in the implicit region advance routine for scalars CCDENSITY.
               ICC = ICC + 1
            ENDDO
         ENDDO
      ENDDO

      ! Cut-cells:
      IF (PREDICTOR) THEN
         DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
            DO JCC=1,CUT_CELL(ICC)%NCELL
               TMPV(0) = CUT_CELL(ICC)%TMP(JCC)
               CALL GET_SENSIBLE_ENTHALPY_Z(N,TMPV(0),H_S)
               CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + &
              (SM%RCON/CUT_CELL(ICC)%RSUM(JCC) - H_S*CUT_CELL(ICC)%R_H_G(JCC))/CUT_CELL(ICC)%RHOS(JCC) * &
              (CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(N,JCC)- CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC))
            ENDDO
         ENDDO
      ELSE
         DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
            DO JCC=1,CUT_CELL(ICC)%NCELL
               TMPV(0) = CUT_CELL(ICC)%TMP(JCC)
               CALL GET_SENSIBLE_ENTHALPY_Z(N,TMPV(0),H_S)
               CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + &
              (SM%RCON/CUT_CELL(ICC)%RSUM(JCC) - H_S*CUT_CELL(ICC)%R_H_G(JCC))/CUT_CELL(ICC)%RHO(JCC) * &
              (CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(N,JCC)- CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC))
            ENDDO
         ENDDO
      ENDIF

   ENDDO SPECIES_LOOP

ENDIF CONST_GAMMA_IF_2

! Add contribution of reactions

IF (N_REACTIONS > 0 .OR. N_LP_ARRAY_INDICES>0 .OR. ANY(SPECIES_MIXTURE%DEPOSITING)) THEN

   ! Regular Cells on the implicit region:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            DPVOL(I,J,K) = DPVOL(I,J,K) + D_SOURCE(I,J,K)*DX(I)*DY(J)*DZ(K)
         ENDDO
      ENDDO
   ENDDO

   ! Cut cells:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + CUT_CELL(ICC)%D_SOURCE(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO
   ENDDO

ENDIF

! Atmospheric stratification term

IF (STRATIFICATION) THEN
   ! Regular Cells on the implicit region:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            DPVOL(I,J,K) = DPVOL(I,J,K) + RTRM(I,J,K)*0.5_EB*(WW(I,J,K)+WW(I,J,K-1))*RHO_0(K)*GVEC(KAXIS)*DX(I)*DY(J)*DZ(K)
         ENDDO
      ENDDO
   ENDDO
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         ! D = D + w*rho_0*g/(rho*Cp*T)*Vii
         CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + CUT_CELL(ICC)%RTRM(JCC)*CUT_CELL(ICC)%WVEL(JCC)* &
                                                             CUT_CELL(ICC)%RHO_0(JCC)*GVEC(KAXIS)*CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO
   ENDDO
ENDIF

! Manufactured solution

MMS_IF: IF (PERIODIC_TEST==7) THEN
   IF (PREDICTOR) TT=T+DT
   IF (CORRECTOR) TT=T
   ! Regular cells on cut-cell region:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            ! this term is similar to D_REACTION from fire
            XHAT = XC(I) - UF_MMS*TT
            ZHAT = ZC(K) - WF_MMS*TT
            DO N=1,N_TRACKED_SPECIES
               SM => SPECIES_MIXTURE(N)
               SELECT CASE(N)
                  CASE(1); Q_Z = -VD2D_MMS_Z_SRC(XHAT,ZHAT,TT)
                  CASE(2); Q_Z =  VD2D_MMS_Z_SRC(XHAT,ZHAT,TT)
               END SELECT
               CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP(I,J,K),H_S)
               DPVOL(I,J,K) = DPVOL(I,J,K) + ( SM%RCON/RSUM(I,J,K) - H_S*R_H_G(I,J,K) )*Q_Z/RHOP(I,J,K)*DX(I)*DY(J)*DZ(K)
            ENDDO
         ENDDO
      ENDDO
   ENDDO
   ! Cut-cells:
   IF (PREDICTOR) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         DO JCC=1,CUT_CELL(ICC)%NCELL
            ! this term is similar to D_REACTION from fire
            XHAT = CUT_CELL(ICC)%XYZCEN(IAXIS,JCC) - UF_MMS*TT
            ZHAT = CUT_CELL(ICC)%XYZCEN(KAXIS,JCC) - WF_MMS*TT
            TMPV(0) = CUT_CELL(ICC)%TMP(JCC)
            DO N=1,N_TRACKED_SPECIES
               SM => SPECIES_MIXTURE(N)
               SELECT CASE(N)
                  CASE(1); Q_Z = -VD2D_MMS_Z_SRC(XHAT,ZHAT,TT)
                  CASE(2); Q_Z =  VD2D_MMS_Z_SRC(XHAT,ZHAT,TT)
               END SELECT
               CALL GET_SENSIBLE_ENTHALPY_Z(N,TMPV(0),H_S)
               CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) +  &
               (SM%RCON/CUT_CELL(ICC)%RSUM(JCC) - H_S*CUT_CELL(ICC)%R_H_G(JCC)) * &
               Q_Z/CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            ENDDO
         ENDDO
      ENDDO
   ELSE ! CORRECTOR
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         DO JCC=1,CUT_CELL(ICC)%NCELL
            ! this term is similar to D_REACTION from fire
            XHAT = CUT_CELL(ICC)%XYZCEN(IAXIS,JCC) - UF_MMS*TT
            ZHAT = CUT_CELL(ICC)%XYZCEN(KAXIS,JCC) - WF_MMS*TT
            TMPV(0) = CUT_CELL(ICC)%TMP(JCC)
            DO N=1,N_TRACKED_SPECIES
               SM => SPECIES_MIXTURE(N)
               SELECT CASE(N)
                  CASE(1); Q_Z = -VD2D_MMS_Z_SRC(XHAT,ZHAT,TT)
                  CASE(2); Q_Z =  VD2D_MMS_Z_SRC(XHAT,ZHAT,TT)
               END SELECT
               CALL GET_SENSIBLE_ENTHALPY_Z(N,TMPV(0),H_S)
               CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) +  &
               (SM%RCON/CUT_CELL(ICC)%RSUM(JCC) - H_S*CUT_CELL(ICC)%R_H_G(JCC)) * &
               Q_Z/CUT_CELL(ICC)%RHO(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            ENDDO
         ENDDO
      ENDDO
   ENDIF
ENDIF MMS_IF

! Assign divergence and 1/(rho*Cp*T) on Cartesian Cells:
AVERAGE_LINKDIV_IF: IF (AVERAGE_LINKDIV) THEN

   ! Average divergence on linked cells:
   ALLOCATE ( DIVRG_VEC(1:NUNKZ_LOCAL) , VOLDVRG(1:NUNKZ_LOCAL), RTRM_VEC(1:NUNKZ_LOCAL) )
   DIVRG_VEC(:) = 0._EB
   VOLDVRG(:)   = 0._EB
   RTRM_VEC(:)  = 0._EB

   ! Add div*vol for all cells and cut-cells on implicit region:
   ! Regular cells:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            ! Unknown number:
            INDZ  = CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
            DIVRG_VEC(INDZ) =  DIVRG_VEC(INDZ) + DPVOL(I,J,K)
            RTRM_VEC(INDZ)  =  RTRM_VEC(INDZ)  + RTRM(I,J,K)*(DX(I)*DY(J)*DZ(K))
            VOLDVRG(INDZ)   =  VOLDVRG(INDZ)   + (DX(I)*DY(J)*DZ(K))
         ENDDO
      ENDDO
   ENDDO

   If (PREDICTOR) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
         DO JCC=1,CUT_CELL(ICC)%NCELL
            INDZ = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            DIVRG_VEC(INDZ) =  DIVRG_VEC(INDZ) + CUT_CELL(ICC)%DVOL(JCC)
            RTRM_VEC(INDZ)  =  RTRM_VEC(INDZ)  + CUT_CELL(ICC)%RTRM(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            VOLDVRG(INDZ)   =  VOLDVRG(INDZ)   + CUT_CELL(ICC)%VOLUME(JCC)
         ENDDO
      ENDDO
   ELSE ! CORRECTOR
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
         DO JCC=1,CUT_CELL(ICC)%NCELL
            INDZ = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            DIVRG_VEC(INDZ) =  DIVRG_VEC(INDZ) + CUT_CELL(ICC)%DVOL(JCC)
            RTRM_VEC(INDZ)  =  RTRM_VEC(INDZ)  + CUT_CELL(ICC)%RTRM(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            VOLDVRG(INDZ)   =  VOLDVRG(INDZ)   + CUT_CELL(ICC)%VOLUME(JCC)
         ENDDO
      ENDDO
   ENDIF

   ! Here there should be a mesh exchange (add) of div*vol for cases where cut-cells are linked to cells
   ! that belong to other meshes.

   ! Compute final divergence:
   DO INDZ=UNKZ_ILC(NM)+1,UNKZ_ILC(NM)+NUNKZ_LOC(NM)
      DIVRG_VEC(INDZ)=DIVRG_VEC(INDZ)/VOLDVRG(INDZ)
      RTRM_VEC(INDZ) = RTRM_VEC(INDZ)/VOLDVRG(INDZ)
   ENDDO

   ! Finally load final thermodynamic divergence to corresponding cells:
   ! Regular cells:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            INDZ  = CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START)
            DP(I,J,K)   = DIVRG_VEC(INDZ) ! Previously divided by VOL.
            RTRM(I,J,K) = RTRM_VEC(INDZ)  ! Previously divided by VOL.
            DEL_RHO_D_DEL_Z(I,J,K,1:N_TRACKED_SPECIES) = DEL_RHO_D_DEL_Z(I,J,K,1:N_TRACKED_SPECIES)/(DX(I)*DY(J)*DZ(K))
         ENDDO
      ENDDO
   ENDDO

   IF (PREDICTOR) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
         DIVVOL = 0._EB
         RTRMVOL= 0._EB
         DO JCC=1,CUT_CELL(ICC)%NCELL
            INDZ = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            CUT_CELL(ICC)%DVOL(JCC)= DIVRG_VEC(INDZ)*CUT_CELL(ICC)%VOLUME(JCC)
            CUT_CELL(ICC)%DS(JCC)  = DIVRG_VEC(INDZ)
            CUT_CELL(ICC)%RTRM(JCC)= RTRM_VEC(INDZ)
            DIVVOL = DIVVOL + CUT_CELL(ICC)%DVOL(JCC)
            RTRMVOL= RTRMVOL+ CUT_CELL(ICC)%RTRM(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
         ENDDO

         ! Now get sum(un*ACFace) and add to divergence:
         DIVVOL_BC=0._EB
         ICF = CCVAR(I,J,K,IBM_IDCF) ! Get CUT_FACE array index which contains INBOUNDARY cut-faces inside cell I,J,K.
         IF(ICF>0) THEN
            DO JCF=1,CUT_FACE(ICF)%NFACE ! Loop all cut-faces inside cell I,J,K
               ICFACE    = CUT_FACE(ICF)%CFACE_INDEX(JCF)  ! Find corresponding CFACE index for this boundary cut-face.
               DIVVOL_BC = DIVVOL_BC - CFACE(ICFACE)%ONE_D%U_NORMAL_S * CFACE(ICFACE)%AREA ! Add flux to BC divergence.
            ENDDO
         ENDIF
         CUT_CELL(ICC)%DIVVOL_BC = DIVVOL_BC
         DP(I,J,K)  = (DIVVOL+DIVVOL_BC)/(DX(I)*DY(J)*DZ(K)) ! Now push Divergence to underlying Cartesian cell.
         RTRM(I,J,K)= RTRMVOL/(DX(I)*DY(J)*DZ(K))
      ENDDO
   ELSE ! CORRECTOR
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
         DIVVOL = 0._EB
         RTRMVOL= 0._EB
         DO JCC=1,CUT_CELL(ICC)%NCELL
            INDZ = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            CUT_CELL(ICC)%DVOL(JCC)= DIVRG_VEC(INDZ)*CUT_CELL(ICC)%VOLUME(JCC)
            CUT_CELL(ICC)%D(JCC)   = DIVRG_VEC(INDZ)
            CUT_CELL(ICC)%RTRM(JCC)= RTRM_VEC(INDZ)
            DIVVOL = DIVVOL + CUT_CELL(ICC)%DVOL(JCC)
            RTRMVOL= RTRMVOL+ CUT_CELL(ICC)%RTRM(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
         ENDDO

         ! Now get sum(un*ACFace) and add to divergence:
         DIVVOL_BC=0._EB
         ICF = CCVAR(I,J,K,IBM_IDCF)
         IF(ICF>0) THEN
            DO JCF=1,CUT_FACE(ICF)%NFACE
               ICFACE    = CUT_FACE(ICF)%CFACE_INDEX(JCF)
               DIVVOL_BC = DIVVOL_BC - CFACE(ICFACE)%ONE_D%U_NORMAL * CFACE(ICFACE)%AREA
            ENDDO
         ENDIF
         CUT_CELL(ICC)%DIVVOL_BC = DIVVOL_BC
         DP(I,J,K) = (DIVVOL+DIVVOL_BC)/(DX(I)*DY(J)*DZ(K))
         RTRM(I,J,K)= RTRMVOL/(DX(I)*DY(J)*DZ(K))
      ENDDO
   ENDIF
   DEALLOCATE ( DIVRG_VEC , VOLDVRG, RTRM_VEC )

ELSE AVERAGE_LINKDIV_IF

   ! Regular cells:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE
            DP(I,J,K) = DPVOL(I,J,K)/(DX(I)*DY(J)*DZ(K))
            DEL_RHO_D_DEL_Z(I,J,K,1:N_TRACKED_SPECIES) = DEL_RHO_D_DEL_Z(I,J,K,1:N_TRACKED_SPECIES)/(DX(I)*DY(J)*DZ(K))
         ENDDO
      ENDDO
   ENDDO

   If (PREDICTOR) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
         DIVVOL = 0._EB
         DO JCC=1,CUT_CELL(ICC)%NCELL
            DIVVOL = DIVVOL + CUT_CELL(ICC)%DVOL(JCC)
         ENDDO
         DP(I,J,K) = DIVVOL/(DX(I)*DY(J)*DZ(K))
      ENDDO
   ELSE ! CORRECTOR
      MINVOL=10000._EB
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
         DIVVOL = 0._EB
         DO JCC=1,CUT_CELL(ICC)%NCELL
            DIVVOL = DIVVOL + CUT_CELL(ICC)%DVOL(JCC)
            MINVOL=MIN(MINVOL,CUT_CELL(ICC)%VOLUME(JCC))
         ENDDO
         DP(I,J,K) = DIVVOL/(DX(I)*DY(J)*DZ(K))
      ENDDO
   ENDIF

ENDIF AVERAGE_LINKDIV_IF

DEALLOCATE(ZZ_GET)

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) &
   T_CC_USED(CCREGION_DIVERGENCE_PART_1_TIME_INDEX) = T_CC_USED(CCREGION_DIVERGENCE_PART_1_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN

CONTAINS

! --------------------------- FIX_CCREGION_DIFF_MASS_FLUXES -------------------------

SUBROUTINE FIX_CCREGION_DIFF_MASS_FLUXES

! IAXIS faces:
X1AXIS = IAXIS
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
   ! Cycle if boundary condition other then INTERPOLATED, OPEN or PERIODIC, already done in GET_BBREGFACE_RHO_D_DZDN.
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==OPEN_BOUNDARY         .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(KAXIS)

   ZZ_FACE(1:N_TRACKED_SPECIES) = 0.5_EB*(ZZP(I+1,J,K,1:N_TRACKED_SPECIES) + &
                                          ZZP(I  ,J,K,1:N_TRACKED_SPECIES))

   N=MAXLOC(ZZ_FACE(1:N_TRACKED_SPECIES),1)

   IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N) = &
   -(SUM(IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(1:N_TRACKED_SPECIES))-IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N))

ENDDO

! JAXIS faces:
X1AXIS = JAXIS
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
   ! Cycle if boundary condition other then INTERPOLATED, OPEN or PERIODIC, already done in GET_BBREGFACE_RHO_D_DZDN.
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==OPEN_BOUNDARY         .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(KAXIS)

   ZZ_FACE(1:N_TRACKED_SPECIES) = 0.5_EB*(ZZP(I,J+1,K,1:N_TRACKED_SPECIES) + &
                                          ZZP(I,J  ,K,1:N_TRACKED_SPECIES))

   N=MAXLOC(ZZ_FACE(1:N_TRACKED_SPECIES),1)

   IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N) = &
   -(SUM(IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(1:N_TRACKED_SPECIES))-IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N))

ENDDO

! KAXIS faces:
X1AXIS = KAXIS
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
   ! Cycle if boundary condition other then INTERPOLATED, OPEN or PERIODIC, already done in GET_BBREGFACE_RHO_D_DZDN.
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==OPEN_BOUNDARY         .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(KAXIS)

   ZZ_FACE(1:N_TRACKED_SPECIES) = 0.5_EB*(ZZP(I,J,K+1,1:N_TRACKED_SPECIES) + &
                                          ZZP(I,J,K  ,1:N_TRACKED_SPECIES))

   N=MAXLOC(ZZ_FACE(1:N_TRACKED_SPECIES),1)

   IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N) = &
   -(SUM(IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(1:N_TRACKED_SPECIES))-IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N))

ENDDO

! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z
   IW = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IWC
   ! Cycle if boundary condition other then INTERPOLATED, OPEN or PERIODIC, already done in GET_BBRCFACE_RHO_D_DZDN.
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==OPEN_BOUNDARY         .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

   ZZ_FACE(1:N_TRACKED_SPECIES) = IBM_RCFACE_Z(IFACE)%ZZ_FACE(1:N_TRACKED_SPECIES)
   N=MAXLOC(ZZ_FACE(1:N_TRACKED_SPECIES),1)

   IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N) = -(SUM(IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(1:N_TRACKED_SPECIES))- &
                                         IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N))

ENDDO


! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = MESHES(NM)%CUT_FACE(ICF)%IWC
   ! Cycle if boundary condition other then INTERPOLATED, OPEN or PERIODIC, already done in GET_BBCUTFACE_RHO_D_DZDN.
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==OPEN_BOUNDARY         .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

   DO IFACE=1,CUT_FACE(ICF)%NFACE
      ZZ_FACE(1:N_TRACKED_SPECIES) = CUT_FACE(ICF)%ZZ_FACE(1:N_TRACKED_SPECIES,IFACE)

      N=MAXLOC(ZZ_FACE(1:N_TRACKED_SPECIES),1)
      CUT_FACE(ICF)%RHO_D_DZDN(N,IFACE) = &
      -(SUM(CUT_FACE(ICF)%RHO_D_DZDN(1:N_TRACKED_SPECIES,IFACE))-CUT_FACE(ICF)%RHO_D_DZDN(N,IFACE))

   ENDDO ! IFACE
ENDDO ! ICF

END SUBROUTINE FIX_CCREGION_DIFF_MASS_FLUXES


! ---------------------------- CCSPECIES_ADVECTION ------------------------------

SUBROUTINE CCSPECIES_ADVECTION


! Computes FV version of flux limited \bar{u dot Grad rho Yalpha} in faces near IB
! region and adds components to thermodynamic divergence.

! Local Variables:
REAL(EB) :: RHO_Z_PV(-2:1), VELC, ALPHAP1, AM_P1, AP_P1, FN_ZZ, ZZ_GET_N
REAL(EB), PARAMETER :: SGNFCT=1._EB
INTEGER :: IOR, ICFA
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()
LOGICAL :: DO_LO,DO_HI

U_DOT_DEL_RHO_Z_VOL=>WORK7
U_DOT_DEL_RHO_Z_VOL=0._EB

! Zero out  for species N in cut-cells:
DO ICC=1,MESHES(NM)%N_CUTCELL_MESH+MESHES(NM)%N_GCCUTCELL_MESH
   DO JCC=1,CUT_CELL(ICC)%NCELL
      CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = 0._EB
   ENDDO
ENDDO

IF (.NOT.ENTHALPY_TRANSPORT) RETURN

! IAXIS faces:
X1AXIS = IAXIS
REGFACE_Z => IBM_REGFACE_IAXIS_Z
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = REGFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I    = REGFACE_Z(IFACE)%IJK(IAXIS)
   J    = REGFACE_Z(IFACE)%IJK(JAXIS)
   K    = REGFACE_Z(IFACE)%IJK(KAXIS)
   DO_LO= REGFACE_Z(IFACE)%DO_LO_IND
   DO_HI= REGFACE_Z(IFACE)%DO_HI_IND
   RHOPV(-1:0)    = RHOP(I:I+1,J,K)
   ! Get rho*zz on cells at both sides of IFACE:
   DO ISIDE=-1,0
      RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZP(I+1+ISIDE,J,K,N)
   ENDDO
   FN_ZZ = REGFACE_Z(IFACE)%FN_ZZ(N) ! bar{rho*zz}
   ! Add: -(bar{rho*zz} u dot n - (rho*zz) u dot n) to corresponding cell DP:
   AF = DY(J)*DZ(K)
   IF(DO_LO) U_DOT_DEL_RHO_Z_VOL(I  ,J,K) = U_DOT_DEL_RHO_Z_VOL(I  ,J,K) + SGNFCT*(FN_ZZ-RHO_Z_PV(-1))*UU(I,J,K)*AF ! +ve dot
   IF(DO_HI) U_DOT_DEL_RHO_Z_VOL(I+1,J,K) = U_DOT_DEL_RHO_Z_VOL(I+1,J,K) - SGNFCT*(FN_ZZ-RHO_Z_PV( 0))*UU(I,J,K)*AF ! -ve dot
ENDDO


! JAXIS faces:
X1AXIS = JAXIS
REGFACE_Z => IBM_REGFACE_JAXIS_Z
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = REGFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I    = REGFACE_Z(IFACE)%IJK(IAXIS)
   J    = REGFACE_Z(IFACE)%IJK(JAXIS)
   K    = REGFACE_Z(IFACE)%IJK(KAXIS)
   DO_LO= REGFACE_Z(IFACE)%DO_LO_IND
   DO_HI= REGFACE_Z(IFACE)%DO_HI_IND
   RHOPV(-1:0)    = RHOP(I,J:J+1,K)
   ! Get rho*hs on cells at both sides of IFACE:
   DO ISIDE=-1,0
      RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZP(I,J+1+ISIDE,K,N)
   ENDDO
   FN_ZZ = REGFACE_Z(IFACE)%FN_ZZ(N) ! bar{rho*zz}
   ! Add: -(bar{rho*zz} u dot n - (rho*zz) u dot n) to corresponding cell DP:
   AF = DX(I)*DZ(K)
   IF(DO_LO) U_DOT_DEL_RHO_Z_VOL(I,J  ,K) = U_DOT_DEL_RHO_Z_VOL(I,J  ,K) + SGNFCT*(FN_ZZ-RHO_Z_PV(-1))*VV(I,J,K)*AF ! +ve dot
   IF(DO_HI) U_DOT_DEL_RHO_Z_VOL(I,J+1,K) = U_DOT_DEL_RHO_Z_VOL(I,J+1,K) - SGNFCT*(FN_ZZ-RHO_Z_PV( 0))*VV(I,J,K)*AF ! -ve dot
ENDDO

! KAXIS faces:
X1AXIS = KAXIS
REGFACE_Z => IBM_REGFACE_KAXIS_Z
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = REGFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I    = REGFACE_Z(IFACE)%IJK(IAXIS)
   J    = REGFACE_Z(IFACE)%IJK(JAXIS)
   K    = REGFACE_Z(IFACE)%IJK(KAXIS)
   DO_LO= REGFACE_Z(IFACE)%DO_LO_IND
   DO_HI= REGFACE_Z(IFACE)%DO_HI_IND
   RHOPV(-1:0)    = RHOP(I,J,K:K+1)
   ! Get rho*zz on cells at both sides of IFACE:
   DO ISIDE=-1,0
      RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZP(I,J,K+1+ISIDE,N)
   ENDDO
   FN_ZZ = REGFACE_Z(IFACE)%FN_ZZ(N) ! bar{rho*zz}
   ! Add: -(bar{rho*zz} u dot n - (rho*zz) u dot n) to corresponding cell DP:
   AF = DX(I)*DY(J)
   IF(DO_LO) U_DOT_DEL_RHO_Z_VOL(I,J,K  ) = U_DOT_DEL_RHO_Z_VOL(I,J,K  ) + SGNFCT*(FN_ZZ-RHO_Z_PV(-1))*WW(I,J,K)*AF ! +ve dot
   IF(DO_HI) U_DOT_DEL_RHO_Z_VOL(I,J,K+1) = U_DOT_DEL_RHO_Z_VOL(I,J,K+1) - SGNFCT*(FN_ZZ-RHO_Z_PV( 0))*WW(I,J,K)*AF ! -ve dot
ENDDO

IF (NEW_SCALAR_TRANSPORT) THEN

! Regular faces connecting gasphase - cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF((IW > 0)) CYCLE ! In new scheme even INTERPOLATED or PERIODIC are treated through RHO_F, ZZ_F(N).
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   RHO_Z_PV(-2:1) = 0._EB
   SELECT CASE(X1AXIS)
      CASE(IAXIS)
         AF = DY(J)*DZ(K)
         RHOPV(-2:1)      = RHOP(I-1:I+2,J,K)
         ! First two cells surrounding face:
         DO ISIDE=-1,0
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDDO
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDIF
         ! Now Godunov flux limited value of rho*zz on face:
         VELC = UU(I,J,K)
         ! bar{rho*zz}:
         FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K) = U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            END SELECT
         ENDDO
      CASE(JAXIS)
         AF = DX(I)*DZ(K)
         RHOPV(-2:1)      = RHOP(I,J-1:J+2,K)
         DO ISIDE=-1,0
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDDO
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDIF
         ! Now Godunov flux limited value of rho*zz on face:
         VELC = VV(I,J,K)
         ! bar{rho*zz}:
         FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K) = U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            END SELECT
         ENDDO
      CASE(KAXIS)
         AF = DX(I)*DY(J)
         RHOPV(-2:1)      = RHOP(I,J,K-1:K+2)
         DO ISIDE=-1,0
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDDO
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDIF
         ! Now Godunov flux limited value of rho*zz on face:
         VELC = WW(I,J,K)
         ! bar{rho*zz}:
         FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE) = U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            END SELECT
         ENDDO
   ENDSELECT
ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF(IW > 0) CYCLE
   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF = CUT_FACE(ICF)%AREA(IFACE)
      RHOPV(-1:0)    = -1._EB
      RHO_Z_PV(-1:0) =  0._EB
      DO ISIDE=-1,0
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
            ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
         END SELECT
         RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
      ENDDO
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
            RHO_Z_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*ZZ_GET_N
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
            RHO_Z_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*ZZ_GET_N
         ENDIF
      CASE(JAXIS)
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
            RHO_Z_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*ZZ_GET_N
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
            RHO_Z_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*ZZ_GET_N
         ENDIF
      CASE(KAXIS)
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
            RHO_Z_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*ZZ_GET_N
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
            RHO_Z_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*ZZ_GET_N
         ENDIF
      END SELECT
      VELC  = PRFCTV *CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCTV)*CUT_FACE(ICF)%VELS(IFACE)
      ! bar{rho*zz}:
      FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
            FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
         END SELECT
      ENDDO
   ENDDO ! IFACE
ENDDO ! ICF

ELSE

! Regular faces connecting gasphase - cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   RHO_Z_PV(-1:0) = 0._EB
   SELECT CASE(X1AXIS)
      CASE(IAXIS)
         AF = DY(J)*DZ(K)
         RHOPV(-1:0)      = RHOP(I:I+1,J,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDDO
         ! Now Godunov flux limited value of rho*zz on face:
         VELC = UU(I,J,K)
         ALPHAP1 = SIGN( 1._EB, VELC )
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
         FN_ZZ = (AM_P1*RHO_Z_PV(-1)+AP_P1*RHO_Z_PV(0)) ! bar{rho*zz}
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K) = U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            END SELECT
         ENDDO
      CASE(JAXIS)
         AF = DX(I)*DZ(K)
         RHOPV(-1:0)      = RHOP(I,J:J+1,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDDO
         ! Now Godunov flux limited value of rho*zz on face:
         VELC = VV(I,J,K)
         ALPHAP1 = SIGN( 1._EB, VELC )
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
         FN_ZZ = (AM_P1*RHO_Z_PV(-1)+AP_P1*RHO_Z_PV(0)) ! bar{rho*zz}
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K) = U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            END SELECT
         ENDDO
      CASE(KAXIS)
         AF = DX(I)*DY(J)
         RHOPV(-1:0)      = RHOP(I,J,K:K+1)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDDO
         ! Now Godunov flux limited value of rho*zz on face:
         VELC = WW(I,J,K)
         ALPHAP1 = SIGN( 1._EB, VELC )
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
         FN_ZZ = (AM_P1*RHO_Z_PV(-1)+AP_P1*RHO_Z_PV(0)) ! bar{rho*zz}
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE) = U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
               FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
            END SELECT
         ENDDO
   ENDSELECT
ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF = CUT_FACE(ICF)%AREA(IFACE)
      ! Interpolate D_Z to the face, linear interpolation:
      RHOPV(-1:0)    = -1._EB
      RHO_Z_PV(-1:0) =  0._EB
      DO ISIDE=-1,0
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
            ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
         END SELECT
         RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
      ENDDO
      VELC  = PRFCTV *CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCTV)*CUT_FACE(ICF)%VELS(IFACE)
      ALPHAP1 = SIGN( 1._EB, VELC )
      AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
      AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
      FN_ZZ = (AM_P1*RHO_Z_PV(-1)+AP_P1*RHO_Z_PV(0)) ! bar{rho*hs}
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) = CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + &
            FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC * AF ! +ve or -ve dot
         END SELECT
      ENDDO
   ENDDO ! IFACE
ENDDO ! ICF

ENDIF

! External Boundary GASPHASE faces:
! IAXIS faces:
X1AXIS = IAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(KAXIS)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   RHOPV(ISIDE)    = RHOP(I+1+ISIDE,J,K)
   RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZP(I+1+ISIDE,J,K,N)
   FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
   SELECT CASE(WC%BOUNDARY_TYPE)
      CASE DEFAULT
         VELC = UU(I,J,K)
      CASE(SOLID_BOUNDARY)
         IF (PREDICTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL_S
         IF (CORRECTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL
   END SELECT
   ! Add: -(bar{rho*zz} u dot n - (rho*zz) u dot n) to corresponding cell DP:
   AF = DY(J)*DZ(K)
   U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K) = U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K) - &
                                        SIGN(1._EB,REAL(IOR,EB))*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
ENDDO

! JAXIS faces:
X1AXIS = JAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(KAXIS)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   RHOPV(ISIDE)    = RHOP(I,J+1+ISIDE,K)
   RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZP(I,J+1+ISIDE,K,N)
   FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
   SELECT CASE(WC%BOUNDARY_TYPE)
      CASE DEFAULT
         VELC = VV(I,J,K)
      CASE(SOLID_BOUNDARY)
         IF (PREDICTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL_S
         IF (CORRECTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL
   END SELECT
   ! Add: -(bar{rho*zz} u dot n - (rho*zz) u dot n) to corresponding cell DP:
   AF = DX(I)*DZ(K)
   U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K) = U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K) - &
                                        SIGN(1._EB,REAL(IOR,EB))*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
ENDDO

! KAXIS faces:
X1AXIS = KAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(KAXIS)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 ->G use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   RHOPV(ISIDE)    = RHOP(I,J,K+1+ISIDE)
   RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZP(I,J,K+1+ISIDE,N)
   FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
   SELECT CASE(WC%BOUNDARY_TYPE)
      CASE DEFAULT
         VELC = WW(I,J,K)
      CASE(SOLID_BOUNDARY)
         IF (PREDICTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL_S
         IF (CORRECTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL
   END SELECT
   ! Add: -(bar{rho*zz} u dot n - (rho*zz) u dot n) to corresponding cell DP:
   AF = DX(I)*DY(J)
   U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE) = U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE) - &
                                        SIGN(1._EB,REAL(IOR,EB))*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
ENDDO

IF (NEW_SCALAR_TRANSPORT) THEN

! Regular Faces connecting gasphase cells to cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC; IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY ) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   ! First (rho hs)_i,j,k:
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      AF = DY(J)*DZ(K)
      VELC = UU(I,J,K)
      RHOPV(ISIDE)      = RHOP(I+1+ISIDE,J,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
      END SELECT
   CASE(JAXIS)
      AF = DX(I)*DZ(K)
      VELC = VV(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J+1+ISIDE,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
      END SELECT
   CASE(KAXIS)
      AF = DX(I)*DY(J)
      VELC = WW(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J,K+1+ISIDE)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
      END SELECT
   END SELECT
   RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
   FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
   SELECT CASE(WC%BOUNDARY_TYPE)
      CASE DEFAULT
         ! Already filled in previous X1AXIS select case.
      CASE(SOLID_BOUNDARY)
         IF (PREDICTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL_S
         IF (CORRECTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL
      CASE(INTERPOLATED_BOUNDARY)
         VELC = UVW_SAVE(IW)
   END SELECT
   SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
   CASE(IBM_FTYPE_RGGAS)
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
        U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K)=U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      CASE(JAXIS)
        U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K)=U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      CASE(KAXIS)
        U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE)=U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      END SELECT
   CASE(IBM_FTYPE_CFGAS) ! Cut-cell
      ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
      JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
      CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)=CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
   END SELECT
ENDDO

! Finally Gasphase cut-faces:
DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY ) CYCLE
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF   = CUT_FACE(ICF)%AREA(IFACE)
      VELC = PRFCT*CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCT)*CUT_FACE(ICF)%VELS(IFACE)
      ! First (rho hs)_i,j,k:
      IF (CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE) == IBM_FTYPE_CFGAS) THEN
        ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
        JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
        RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
        ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
        RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
        CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)=CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      ENDIF
   ENDDO ! IFACE
ENDDO ! ICF

ELSE ! NEW_SCALAR_TRANSPORT

! Regular Faces connecting gasphase cells to cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   ! First (rho hs)_i,j,k:
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      AF = DY(J)*DZ(K)
      VELC = UU(I,J,K)
      RHOPV(ISIDE)      = RHOP(I+1+ISIDE,J,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
      END SELECT
   CASE(JAXIS)
      AF = DX(I)*DZ(K)
      VELC = VV(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J+1+ISIDE,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
      END SELECT
   CASE(KAXIS)
      AF = DX(I)*DY(J)
      VELC = WW(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J,K+1+ISIDE)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
      END SELECT
   END SELECT
   RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
   FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
   SELECT CASE(WC%BOUNDARY_TYPE)
      CASE DEFAULT
         ! Already filled in previous X1AXIS select case.
      CASE(SOLID_BOUNDARY)
         IF (PREDICTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL_S
         IF (CORRECTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL
   END SELECT
   SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
   CASE(IBM_FTYPE_RGGAS)
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
        U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K)=U_DOT_DEL_RHO_Z_VOL(I+1+ISIDE,J,K)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      CASE(JAXIS)
        U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K)=U_DOT_DEL_RHO_Z_VOL(I,J+1+ISIDE,K)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      CASE(KAXIS)
        U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE)=U_DOT_DEL_RHO_Z_VOL(I,J,K+1+ISIDE)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      END SELECT
   CASE(IBM_FTYPE_CFGAS) ! Cut-cell
      ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
      JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
      CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)=CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
   END SELECT
ENDDO

! Finally Gasphase cut-faces:
DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N)
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF   = CUT_FACE(ICF)%AREA(IFACE)
      VELC = PRFCT*CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCT)*CUT_FACE(ICF)%VELS(IFACE)
      ! First (rho hs)_i,j,k:
      IF (CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE) == IBM_FTYPE_CFGAS) THEN
        ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
        JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
        RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
        ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
        RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
        CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)=CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)+FCT*SGNFCT*(FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
      ENDIF
   ENDDO ! IFACE
ENDDO ! ICF

ENDIF ! NEW_SCALAR_TRANSPORT

! INBOUNDARY cut-faces:
! Species advection due to INBOUNDARY cut-faces (CFACE):
ISIDE=-1
CFACE_LOOP : DO ICFA=1,N_CFACE_CELLS
   CFA => CFACE(ICFA)
   ! Find associated cut-cell:
   IND1=CFA%CUT_FACE_IND1
   IND2=CFA%CUT_FACE_IND2
   ICC = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2)
   JCC = CUT_FACE(IND1)%CELL_LIST(3,LOW_IND,IND2)
   AF  = CFA%AREA
   VELC= PRFCT*CFA%ONE_D%U_NORMAL + (1._EB-PRFCT)*CFA%ONE_D%U_NORMAL_S
   ! Takes place of flux limited interpolation:
   FN_ZZ        = CFA%ONE_D%RHO_F * CFA%ONE_D%ZZ_F(N)
   RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
   ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
   ! Cut-cell value of rho*Z:
   RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
   ! Add to U_DOT_DEL_RHO_Z:                                        ! (\bar{rho*Z}_CFACE - (rho*Z)_CC)*VELOUT*AF
   CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC)=CUT_CELL(ICC)%U_DOT_DEL_RHO_Z_VOL(N,JCC) + (FN_ZZ-RHO_Z_PV(ISIDE))*VELC*AF
ENDDO CFACE_LOOP

RETURN
END SUBROUTINE CCSPECIES_ADVECTION


! ---------------------------- CCENTHALPY_ADVECTION -----------------------------

SUBROUTINE CCENTHALPY_ADVECTION


! Computes FV version of flux limited \bar{ u dot Grad rho hs} in faces of near IB
! region and adds components to thermodynamic divergence.


! Local Variables:
REAL(EB) :: RHO_H_S_PV(-2:1), VELC, VELC2, ALPHAP1, AM_P1, AP_P1, FN_H_S, TMP_F_GAS
INTEGER  :: IOR, ICFA
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()
LOGICAL :: DO_LO, DO_HI

IF (.NOT.ENTHALPY_TRANSPORT) RETURN

! IAXIS faces:
X1AXIS = IAXIS
REGFACE_Z => IBM_REGFACE_IAXIS_Z
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = REGFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I    = REGFACE_Z(IFACE)%IJK(IAXIS)
   J    = REGFACE_Z(IFACE)%IJK(JAXIS)
   K    = REGFACE_Z(IFACE)%IJK(KAXIS)
   DO_LO= REGFACE_Z(IFACE)%DO_LO_IND
   DO_HI= REGFACE_Z(IFACE)%DO_HI_IND
   RHOPV(-1:0)      = RHOP(I:I+1,J,K)
   TMPV(-1:0)       =  TMP(I:I+1,J,K)
   RHO_H_S_PV(-1:0) = 0._EB
   ! Get rho*hs on cells at both sides of IFACE:
   DO ISIDE=-1,0
      ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
      RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
   ENDDO
   ! Add: -(bar{rho*hs} u dot n - (rho*hs) u dot n) to corresponding cell DP:
   AF = DY(J)*DZ(K)
   IF(DO_LO) DPVOL(I  ,J,K) = DPVOL(I  ,J,K) + (-1._EB)*(REGFACE_Z(IFACE)%FN_H_S-RHO_H_S_PV(-1))*UU(I,J,K)*AF ! +ve dot
   IF(DO_HI) DPVOL(I+1,J,K) = DPVOL(I+1,J,K) - (-1._EB)*(REGFACE_Z(IFACE)%FN_H_S-RHO_H_S_PV( 0))*UU(I,J,K)*AF ! -ve dot
ENDDO

! JAXIS faces:
X1AXIS = JAXIS
REGFACE_Z => IBM_REGFACE_JAXIS_Z
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = REGFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I    = REGFACE_Z(IFACE)%IJK(IAXIS)
   J    = REGFACE_Z(IFACE)%IJK(JAXIS)
   K    = REGFACE_Z(IFACE)%IJK(KAXIS)
   DO_LO= REGFACE_Z(IFACE)%DO_LO_IND
   DO_HI= REGFACE_Z(IFACE)%DO_HI_IND
   RHOPV(-1:0)      = RHOP(I,J:J+1,K)
   TMPV(-1:0)       =  TMP(I,J:J+1,K)
   RHO_H_S_PV(-1:0) = 0._EB
   ! Get rho*hs on cells at both sides of IFACE:
   DO ISIDE=-1,0
      ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
      RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
   ENDDO
   ! Add: -(bar{rho*hs} u dot n - (rho*hs) u dot n) to corresponding cell DP:
   AF = DX(I)*DZ(K)
   IF(DO_LO) DPVOL(I,J  ,K) = DPVOL(I,J  ,K) + (-1._EB)*(REGFACE_Z(IFACE)%FN_H_S-RHO_H_S_PV(-1))*VV(I,J,K)*AF ! +ve dot
   IF(DO_HI) DPVOL(I,J+1,K) = DPVOL(I,J+1,K) - (-1._EB)*(REGFACE_Z(IFACE)%FN_H_S-RHO_H_S_PV( 0))*VV(I,J,K)*AF ! -ve dot
ENDDO

! KAXIS faces:
X1AXIS = KAXIS
REGFACE_Z => IBM_REGFACE_KAXIS_Z
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
   IW = REGFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I    = REGFACE_Z(IFACE)%IJK(IAXIS)
   J    = REGFACE_Z(IFACE)%IJK(JAXIS)
   K    = REGFACE_Z(IFACE)%IJK(KAXIS)
   DO_LO= REGFACE_Z(IFACE)%DO_LO_IND
   DO_HI= REGFACE_Z(IFACE)%DO_HI_IND
   RHOPV(-1:0)      = RHOP(I,J,K:K+1)
   TMPV(-1:0)       =  TMP(I,J,K:K+1)
   RHO_H_S_PV(-1:0) = 0._EB
   ! Get rho*hs on cells at both sides of IFACE:
   DO ISIDE=-1,0
      ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
      CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
      RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
   ENDDO
   ! Add: -(bar{rho*hs} u dot n - (rho*hs) u dot n) to corresponding cell DP:
   AF = DX(I)*DY(J)
   IF(DO_LO) DPVOL(I,J,K  ) = DPVOL(I,J,K  ) + (-1._EB)*(REGFACE_Z(IFACE)%FN_H_S-RHO_H_S_PV(-1))*WW(I,J,K)*AF ! +ve dot
   IF(DO_HI) DPVOL(I,J,K+1) = DPVOL(I,J,K+1) - (-1._EB)*(REGFACE_Z(IFACE)%FN_H_S-RHO_H_S_PV( 0))*WW(I,J,K)*AF ! -ve dot
ENDDO

IF (NEW_SCALAR_TRANSPORT) THEN

! Regular faces connecting gasphase - cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF( IW > 0 ) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   RHO_H_S_PV(-2:1) = 0._EB
   SELECT CASE(X1AXIS)
      CASE(IAXIS)
         AF = DY(J)*DZ(K)
         RHOPV(-1:0)      = RHOP(I:I+1,J,K)
         TMPV(-1:0)       =  TMP(I:I+1,J,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                       (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
            RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         ENDDO
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I+1+ISIDE,J,K))
            RHO_H_S_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*H_S
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I+1+ISIDE,J,K))
            RHO_H_S_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*H_S
         ENDIF
         ! Now Godunov flux limited value of rho*hs on face:
         VELC = UU(I,J,K)
         FN_H_S = SCALAR_FACE_VALUE(VELC,RHO_H_S_PV(-2:1),I_FLUX_LIMITER)
         ! Add contribution to DP:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I+1+ISIDE,J,K)=DPVOL(I+1+ISIDE,J,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
            END SELECT
         ENDDO

      CASE(JAXIS)
         AF = DX(I)*DZ(K)
         RHOPV(-1:0)      = RHOP(I,J:J+1,K)
         TMPV(-1:0)       =  TMP(I,J:J+1,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                       (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
            RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         ENDDO
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J+1+ISIDE,K))
            RHO_H_S_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*H_S
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J+1+ISIDE,K))
            RHO_H_S_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*H_S
         ENDIF
         ! Now Godunov flux limited value of rho*hs on face:
         VELC = VV(I,J,K)
         FN_H_S = SCALAR_FACE_VALUE(VELC,RHO_H_S_PV(-2:1),I_FLUX_LIMITER)
         ! Add contribution to DP:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I,J+1+ISIDE,K)=DPVOL(I,J+1+ISIDE,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
            END SELECT
         ENDDO

      CASE(KAXIS)
         AF = DX(I)*DY(J)
         RHOPV(-1:0)      = RHOP(I,J,K:K+1)
         TMPV(-1:0)       =  TMP(I,J,K:K+1)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                       (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
            RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         ENDDO
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J,K+1+ISIDE))
            RHO_H_S_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*H_S
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J,K+1+ISIDE))
            RHO_H_S_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*H_S
         ENDIF
         ! Now Godunov flux limited value of rho*hs on face:
         VELC = WW(I,J,K)
         FN_H_S = SCALAR_FACE_VALUE(VELC,RHO_H_S_PV(-2:1),I_FLUX_LIMITER)
         ! Add contribution to DP:
         ! Low side cell:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I,J,K+1+ISIDE)=DPVOL(I,J,K+1+ISIDE)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
            END SELECT
         ENDDO

   ENDSELECT

ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF(IW > 0) CYCLE
   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF = CUT_FACE(ICF)%AREA(IFACE)
      RHOPV(-1:0)      = -1._EB
      TMPV(-1:0)       = -1._EB
      RHO_H_S_PV(-2:1) =  0._EB
      DO ISIDE=-1,0
         ZZ_GET = 0._EB
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
            RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
            ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                    (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
         END SELECT
         CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
         RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
      ENDDO
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I+1+ISIDE,J,K))
            RHO_H_S_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*H_S
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I+1+ISIDE,J,K))
            RHO_H_S_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*H_S
         ENDIF
      CASE(JAXIS)
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J+1+ISIDE,K))
            RHO_H_S_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*H_S
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J+1+ISIDE,K))
            RHO_H_S_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*H_S
         ENDIF
      CASE(KAXIS)
         ! Lower cell:
         ISIDE=-2
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE+1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J,K+1+ISIDE))
            RHO_H_S_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*H_S
         ENDIF
         ! Upper cell:
         ISIDE=1
         IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
            RHO_H_S_PV(ISIDE) = RHO_H_S_PV(ISIDE-1) ! Use center cell.
         ELSE
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP(I,J,K+1+ISIDE))
            RHO_H_S_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*H_S
         ENDIF
      END SELECT
      VELC    = PRFCTV *CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCTV)*CUT_FACE(ICF)%VELS(IFACE)
      FN_H_S  = SCALAR_FACE_VALUE(VELC,RHO_H_S_PV(-2:1),I_FLUX_LIMITER)
      ! Add to divergence integral of surrounding cut-cells:
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
         END SELECT
      ENDDO
   ENDDO ! IFACE
ENDDO ! ICF

ELSE ! NEW_SCALAR_TRANSPORT

! Regular faces connecting gasphase - cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   RHO_H_S_PV(-1:0) = 0._EB
   SELECT CASE(X1AXIS)
      CASE(IAXIS)
         AF = DY(J)*DZ(K)
         RHOPV(-1:0)      = RHOP(I:I+1,J,K)
         TMPV(-1:0)       =  TMP(I:I+1,J,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                       (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
            RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         ENDDO

         ! Now Godunov flux limited value of rho*hs on face:
         VELC = UU(I,J,K)
         ALPHAP1 = SIGN( 1._EB, VELC )
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
         FN_H_S = (AM_P1*RHO_H_S_PV(-1)+AP_P1*RHO_H_S_PV(0)) ! bar{rho*hs}

         ! Add contribution to DP:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I+1+ISIDE,J,K)=DPVOL(I+1+ISIDE,J,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
            END SELECT
         ENDDO

      CASE(JAXIS)
         AF = DX(I)*DZ(K)
         RHOPV(-1:0)      = RHOP(I,J:J+1,K)
         TMPV(-1:0)       =  TMP(I,J:J+1,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                       (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
            RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         ENDDO

         ! Now Godunov flux limited value of rho*hs on face:
         VELC = VV(I,J,K)
         ALPHAP1 = SIGN( 1._EB, VELC )
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
         FN_H_S = (AM_P1*RHO_H_S_PV(-1)+AP_P1*RHO_H_S_PV(0)) ! bar{rho*hs}

         ! Add contribution to DP:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I,J+1+ISIDE,K)=DPVOL(I,J+1+ISIDE,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
            END SELECT
         ENDDO

      CASE(KAXIS)
         AF = DX(I)*DY(J)
         RHOPV(-1:0)      = RHOP(I,J,K:K+1)
         TMPV(-1:0)       =  TMP(I,J,K:K+1)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                       (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
            RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         ENDDO

         ! Now Godunov flux limited value of rho*hs on face:
         VELC = WW(I,J,K)
         ALPHAP1 = SIGN( 1._EB, VELC )
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
         FN_H_S = (AM_P1*RHO_H_S_PV(-1)+AP_P1*RHO_H_S_PV(0)) ! bar{rho*hs}

         ! Add contribution to DP:
         ! Low side cell:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I,J,K+1+ISIDE)=DPVOL(I,J,K+1+ISIDE)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
            END SELECT
         ENDDO

   ENDSELECT

ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF = CUT_FACE(ICF)%AREA(IFACE)
      RHOPV(-1:0)      = -1._EB
      TMPV(-1:0)       = -1._EB
      RHO_H_S_PV(-1:0) =  0._EB
      DO ISIDE=-1,0
         ZZ_GET = 0._EB
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
            RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
            ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                    (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
         END SELECT
         CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
         RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
      ENDDO

      VELC    = PRFCTV *CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCTV)*CUT_FACE(ICF)%VELS(IFACE)
      ALPHAP1 = SIGN( 1._EB, VELC )
      AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
      AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
      FN_H_S = (AM_P1*RHO_H_S_PV(-1)+AP_P1*RHO_H_S_PV(0)) ! bar{rho*hs}

      ! Add to divergence integral of surrounding cut-cells:
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
         END SELECT
      ENDDO
   ENDDO ! IFACE
ENDDO ! ICF

ENDIF ! NEW_SCALAR_TRANSPORT

! Now work with boundary faces:
! IAXIS faces:
X1AXIS = IAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(KAXIS)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   RHOPV(ISIDE)      = RHOP(I+1+ISIDE,J,K)
   TMPV(ISIDE)       =  TMP(I+1+ISIDE,J,K)
   ! Get rho*hs on cells at both sides of IFACE:
   ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
   RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
   ! Calculate the sensible enthalpy at the boundary. If the boundary is solid
   ! and the gas is flowing out, use the gas temperature for the calculation.
   VELC      = UU(I,J,K)
   VELC2     = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
   TMP_F_GAS = WC%ONE_D%TMP_F
   IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY) THEN
      VELC = -SIGN(1._EB,REAL(IOR,EB))*VELC2
      IF (VELC2>0._EB) TMP_F_GAS = WC%ONE_D%TMP_G
   ENDIF
   ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
   ! Add: -(bar{rho*hs} u dot n - (rho*hs) u dot n) to corresponding cell DP:
   AF = DY(J)*DZ(K)
   DPVOL(I+1+ISIDE,J,K) = DPVOL(I+1+ISIDE,J,K) + SIGN(1._EB,REAL(IOR,EB))*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
ENDDO

! JAXIS faces:
X1AXIS = JAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(KAXIS)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   RHOPV(ISIDE)      = RHOP(I,J+1+ISIDE,K)
   TMPV(ISIDE)       =  TMP(I,J+1+ISIDE,K)
   ! Get rho*hs on cells at both sides of IFACE:
   ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
   RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
   ! Calculate the sensible enthalpy at the boundary. If the boundary is solid
   ! and the gas is flowing out, use the gas temperature for the calculation.
   VELC      = VV(I,J,K)
   VELC2     = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
   TMP_F_GAS = WC%ONE_D%TMP_F
   IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY) THEN
      VELC = -SIGN(1._EB,REAL(IOR,EB))*VELC2
      IF (VELC2>0._EB) TMP_F_GAS = WC%ONE_D%TMP_G
   ENDIF
   ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
   ! Add: -(bar{rho*hs} u dot n - (rho*hs) u dot n) to corresponding cell DP:
   AF = DX(I)*DZ(K)
   DPVOL(I,J+1+ISIDE,K) = DPVOL(I,J+1+ISIDE,K) + SIGN(1._EB,REAL(IOR,EB))*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
ENDDO

! KAXIS faces:
X1AXIS = KAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(KAXIS)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   RHOPV(ISIDE)      = RHOP(I,J,K+1+ISIDE)
   TMPV(ISIDE)       =  TMP(I,J,K+1+ISIDE)
   ! Get rho*hs on cells at both sides of IFACE:
   ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
   RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
   ! Calculate the sensible enthalpy at the boundary. If the boundary is solid
   ! and the gas is flowing out, use the gas temperature for the calculation.
   VELC      = WW(I,J,K)
   VELC2     = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
   TMP_F_GAS = WC%ONE_D%TMP_F
   IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY) THEN
      VELC = -SIGN(1._EB,REAL(IOR,EB))*VELC2
      IF (VELC2>0._EB) TMP_F_GAS = WC%ONE_D%TMP_G
   ENDIF
   ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
   ! Add: -(bar{rho*hs} u dot n - (rho*hs) u dot n) to corresponding cell DP:
   AF = DX(I)*DY(J)
   DPVOL(I,J,K+1+ISIDE) = DPVOL(I,J,K+1+ISIDE) + SIGN(1._EB,REAL(IOR,EB))*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
ENDDO


IF (NEW_SCALAR_TRANSPORT) THEN

! Regular Faces connecting gasphase cells to cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY ) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT   = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   ! First (rho hs)_i,j,k:
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      AF = DY(J)*DZ(K)
      VELC = UU(I,J,K)
      RHOPV(ISIDE)      = RHOP(I+1+ISIDE,J,K)
      TMPV(ISIDE)       =  TMP(I+1+ISIDE,J,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
      END SELECT
   CASE(JAXIS)
      AF = DX(I)*DZ(K)
      VELC = VV(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J+1+ISIDE,K)
      TMPV(ISIDE)       =  TMP(I,J+1+ISIDE,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
      END SELECT
   CASE(KAXIS)
      AF = DX(I)*DY(J)
      VELC = WW(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J,K+1+ISIDE)
      TMPV(ISIDE)       =  TMP(I,J,K+1+ISIDE)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
      END SELECT
   END SELECT
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
   RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S

   ! Flux limited face value bar{rho*hs}_F
   ! Calculate the sensible enthalpy at the boundary. If the boundary is solid
   ! and the gas is flowing out, use the gas temperature for the calculation.
   VELC2     = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
   TMP_F_GAS = WC%ONE_D%TMP_F
   SELECT CASE(WC%BOUNDARY_TYPE)
      CASE DEFAULT
         ! No need to do anything, populated before.
      CASE(SOLID_BOUNDARY)
         VELC = -SIGN(1._EB,REAL(IOR,EB))*VELC2
         IF (VELC2>0._EB) TMP_F_GAS = WC%ONE_D%TMP_G
      CASE(INTERPOLATED_BOUNDARY)
         VELC = UVW_SAVE(IW)
   END SELECT
   ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
   ! Finally add to Div:
   SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
   CASE(IBM_FTYPE_RGGAS) ! Regular cell
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         DPVOL(I+1+ISIDE,J,K)=DPVOL(I+1+ISIDE,J,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
      CASE(JAXIS)
         DPVOL(I,J+1+ISIDE,K)=DPVOL(I,J+1+ISIDE,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
      CASE(KAXIS)
         DPVOL(I,J,K+1+ISIDE)=DPVOL(I,J,K+1+ISIDE)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
      END SELECT
   CASE(IBM_FTYPE_CFGAS) ! Cut-cell
      ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
      JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
      CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
   END SELECT
ENDDO

! Finally Gasphase cut-faces:
DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY ) CYCLE
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! Flux limited face value bar{rho*hs}_F, the ONE_D variable values fo TMP, RHOP, ZZ and RSUM have been averaged to
   ! the cartesian cell location in CCREGION_DENSITY:
   VELC2     = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
   TMP_F_GAS = WC%ONE_D%TMP_F
   IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY .AND. VELC2>0._EB) TMP_F_GAS = WC%ONE_D%TMP_G
   ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF   = CUT_FACE(ICF)%AREA(IFACE)
      VELC = PRFCT*CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCT)*CUT_FACE(ICF)%VELS(IFACE)
      ! Here if INTERPOLATED_BOUNDARY we might need UVW_SAVE.
      ! First (rho hs)_i,j,k:
      SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
         JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
         CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
         RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF ! +ve or -ve dot
      END SELECT
   ENDDO ! IFACE
ENDDO ! ICF

ELSE ! NEW_SCALAR_TRANSPORT

! Regular Faces connecting gasphase cells to cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT   = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   ! First (rho hs)_i,j,k:
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      AF = DY(J)*DZ(K)
      VELC = UU(I,J,K)
      RHOPV(ISIDE)      = RHOP(I+1+ISIDE,J,K)
      TMPV(ISIDE)       =  TMP(I+1+ISIDE,J,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
      END SELECT
   CASE(JAXIS)
      AF = DX(I)*DZ(K)
      VELC = VV(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J+1+ISIDE,K)
      TMPV(ISIDE)       =  TMP(I,J+1+ISIDE,K)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
      END SELECT
   CASE(KAXIS)
      AF = DX(I)*DY(J)
      VELC = WW(I,J,K)
      RHOPV(ISIDE)      = RHOP(I,J,K+1+ISIDE)
      TMPV(ISIDE)       =  TMP(I,J,K+1+ISIDE)
      SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
      CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
      END SELECT
   END SELECT
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
   RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S

   ! Flux limited face value bar{rho*hs}_F
   ! Calculate the sensible enthalpy at the boundary. If the boundary is solid
   ! and the gas is flowing out, use the gas temperature for the calculation.
   VELC2     = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
   TMP_F_GAS = WC%ONE_D%TMP_F
   IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY) THEN
      VELC = -SIGN(1._EB,REAL(IOR,EB))*VELC2
      IF (VELC2>0._EB) TMP_F_GAS = WC%ONE_D%TMP_G
   ENDIF
   ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
   ! Finally add to Div:
   SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
   CASE(IBM_FTYPE_RGGAS) ! Regular cell
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         DPVOL(I+1+ISIDE,J,K)=DPVOL(I+1+ISIDE,J,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF !+ve/-ve dot
      CASE(JAXIS)
         DPVOL(I,J+1+ISIDE,K)=DPVOL(I,J+1+ISIDE,K)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
      CASE(KAXIS)
         DPVOL(I,J,K+1+ISIDE)=DPVOL(I,J,K+1+ISIDE)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
      END SELECT
   CASE(IBM_FTYPE_CFGAS) ! Cut-cell
      ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
      JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
      CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF
   END SELECT
ENDDO

! Finally Gasphase cut-faces:
DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! Flux limited face value bar{rho*hs}_F, the ONE_D variable values fo TMP, RHOP, ZZ and RSUM have been averaged to
   ! the cartesian cell location in CCREGION_DENSITY:
   VELC2     = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
   TMP_F_GAS = WC%ONE_D%TMP_F
   IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY .AND. VELC2>0._EB) TMP_F_GAS = WC%ONE_D%TMP_G
   ZZ_GET(1:N_TRACKED_SPECIES) = WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = WC%ONE_D%RHO_F*H_S ! bar{rho*hs}
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF   = CUT_FACE(ICF)%AREA(IFACE)
      VELC = PRFCT*CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCT)*CUT_FACE(ICF)%VELS(IFACE)
      ! First (rho hs)_i,j,k:
      SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
         JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
         TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
         RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
         ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
         CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
         RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
         CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF ! +ve or -ve dot
      END SELECT
   ENDDO ! IFACE
ENDDO ! ICF

ENDIF ! NEW_SCALAR_TRANSPORT

! Enthalpy advection due to INBOUNDARY cut-faces (CFACE):
ISIDE=-1
CFACE_LOOP : DO ICFA=1,N_CFACE_CELLS
   CFA => CFACE(ICFA)
   ! Find associated cut-cell:
   IND1=CFA%CUT_FACE_IND1
   IND2=CFA%CUT_FACE_IND2
   ICC = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2)
   JCC = CUT_FACE(IND1)%CELL_LIST(3,LOW_IND,IND2)
   AF = CFA%AREA
   VELC      = PRFCT*CFA%ONE_D%U_NORMAL + (1._EB-PRFCT)*CFA%ONE_D%U_NORMAL_S
   TMP_F_GAS = CFA%ONE_D%TMP_F
   IF (VELC>0._EB) TMP_F_GAS = CFA%ONE_D%TMP_G ! CUT_CELL(ICC)%TMP(JCC)
   ZZ_GET(1:N_TRACKED_SPECIES) = CFA%ONE_D%ZZ_F(1:N_TRACKED_SPECIES)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMP_F_GAS)
   FN_H_S = CFA%ONE_D%RHO_F*H_S ! bar{rho*hs}

   TMPV(ISIDE)  = CUT_CELL(ICC)%TMP(JCC)
   RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
   ZZ_GET(1:N_TRACKED_SPECIES) = PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                          (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
   CALL GET_SENSIBLE_ENTHALPY(ZZ_GET,H_S,TMPV(ISIDE))
   RHO_H_S_PV(ISIDE) = RHOPV(ISIDE)*H_S
   CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+(-1._EB)*(FN_H_S-RHO_H_S_PV(ISIDE))*VELC*AF ! +ve or -ve dot
ENDDO CFACE_LOOP

RETURN
END SUBROUTINE CCENTHALPY_ADVECTION

! ----------------------- CCREGION_DIFFUSIVE_HEAT_FLUXES ------------------------

SUBROUTINE CCREGION_DIFFUSIVE_HEAT_FLUXES

! NOTE: this routine assumes POINT_TO_MESH(NM) has been previously called.

! Local Variables:
INTEGER :: IIG, JJG, KKG , IOR, N_ZZ_MAX
REAL(EB) :: UN_P, RHO_D_DZDN
REAL(EB) :: RHO_D_DZDN_GET(1:N_TRACKED_SPECIES)
TYPE(CFACE_TYPE), POINTER :: CFA=>NULL()
LOGICAL :: DO_LO, DO_HI

SPECIES_LOOP1: DO N=1,N_TOTAL_SCALARS

   ! IAXIS faces:
   X1AXIS = IAXIS
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

      I     = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(IAXIS)
      J     = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(JAXIS)
      K     = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(KAXIS)
      DO_LO = IBM_REGFACE_IAXIS_Z(IFACE)%DO_LO_IND
      DO_HI = IBM_REGFACE_IAXIS_Z(IFACE)%DO_HI_IND

      ! H_RHO_D_DZDN
      TMP_G = 0.5_EB*(TMP(I+1,J,K)+TMP(I,J,K))
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      IBM_REGFACE_IAXIS_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N)

      ! Add H_RHO_D_DZDN dot n to corresponding cell DP. Add to int(DEL_RHO_D_DEL_Z)dv in FV form:
      AF = DY(J)*DZ(K)
      IF (DO_LO) THEN
         DPVOL(I  ,J,K) = DPVOL(I  ,J,K) + IBM_REGFACE_IAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! +ve dot
         DEL_RHO_D_DEL_Z(I  ,J,K,N)=DEL_RHO_D_DEL_Z(I  ,J,K,N)+IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N)*AF !+ dot
      ENDIF
      IF (DO_HI) THEN
         DPVOL(I+1,J,K) = DPVOL(I+1,J,K) - IBM_REGFACE_IAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! -ve dot
         DEL_RHO_D_DEL_Z(I+1,J,K,N)=DEL_RHO_D_DEL_Z(I+1,J,K,N)-IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N)*AF !- dot
      ENDIF
   ENDDO

   ! JAXIS faces:
   X1AXIS = JAXIS
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

      I     = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(IAXIS)
      J     = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(JAXIS)
      K     = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(KAXIS)
      DO_LO = IBM_REGFACE_JAXIS_Z(IFACE)%DO_LO_IND
      DO_HI = IBM_REGFACE_JAXIS_Z(IFACE)%DO_HI_IND

      ! H_RHO_D_DZDN
      TMP_G = 0.5_EB*(TMP(I,J+1,K)+TMP(I,J,K))
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      IBM_REGFACE_JAXIS_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N)

      ! Add H_RHO_D_DZDN dot n to corresponding cell DP. Add to int(DEL_RHO_D_DEL_Z)dv in FV form:
      AF = DX(I)*DZ(K)
      IF (DO_LO) THEN
         DPVOL(I,J  ,K) = DPVOL(I,J  ,K) + IBM_REGFACE_JAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! +ve dot
         DEL_RHO_D_DEL_Z(I,J  ,K,N)=DEL_RHO_D_DEL_Z(I,J  ,K,N)+IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N)*AF !+ dot
      ENDIF
      IF (DO_HI) THEN
         DPVOL(I,J+1,K) = DPVOL(I,J+1,K) - IBM_REGFACE_JAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! -ve dot
         DEL_RHO_D_DEL_Z(I,J+1,K,N)=DEL_RHO_D_DEL_Z(I,J+1,K,N)-IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N)*AF !- dot
      ENDIF
   ENDDO

   ! KAXIS faces:
   X1AXIS = KAXIS
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
      I     = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(IAXIS)
      J     = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(JAXIS)
      K     = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(KAXIS)
      DO_LO = IBM_REGFACE_KAXIS_Z(IFACE)%DO_LO_IND
      DO_HI = IBM_REGFACE_KAXIS_Z(IFACE)%DO_HI_IND

      ! H_RHO_D_DZDN
      TMP_G = 0.5_EB*(TMP(I,J,K+1)+TMP(I,J,K))
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      IBM_REGFACE_KAXIS_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N)

      ! Add H_RHO_D_DZDN dot n to corresponding cell DP. Add to int(DEL_RHO_D_DEL_Z)dv in FV form:
      AF = DX(I)*DY(J)
      IF (DO_LO) THEN
         DPVOL(I,J,K  ) = DPVOL(I,J,K  ) + IBM_REGFACE_KAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! +ve dot
         DEL_RHO_D_DEL_Z(I,J,K  ,N)=DEL_RHO_D_DEL_Z(I,J,K  ,N)+IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N)*AF !+ dot
      ENDIF
      IF (DO_HI) THEN
         DPVOL(I,J,K+1) = DPVOL(I,J,K+1) - IBM_REGFACE_KAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! -ve dot
         DEL_RHO_D_DEL_Z(I,J,K+1,N)=DEL_RHO_D_DEL_Z(I,J,K+1,N)-IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N)*AF !- dot
      ENDIF
   ENDDO

ENDDO SPECIES_LOOP1

! Regular faces connecting gasphase- cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   TMP_G  = IBM_RCFACE_Z(IFACE)%TMP_FACE
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      AF = DY(J)*DZ(K)
      ! H_RHO_D_DZDN
      DO N=1,N_TOTAL_SCALARS
         CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
         IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)
      ENDDO
      ! Add contribution to DP:
      ! Low side cell:
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
         CASE(IBM_FTYPE_RGGAS) ! Regular cell
         DPVOL(I+1+ISIDE,J,K)=DPVOL(I+1+ISIDE,J,K)+FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF
         ! +ve or -ve dot
         DO N=1,N_TOTAL_SCALARS
         DEL_RHO_D_DEL_Z(I+1+ISIDE,J,K,N)=DEL_RHO_D_DEL_Z(I+1+ISIDE,J,K,N)+FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)*AF
         ENDDO
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF !+/- dot
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)= &
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)+FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(1:N_TOTAL_SCALARS)*AF
         END SELECT
      ENDDO
   CASE(JAXIS)
      AF = DX(I)*DZ(K)
      ! H_RHO_D_DZDN
      DO N=1,N_TOTAL_SCALARS
         CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
         IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)
      ENDDO
      ! Add contribution to DP:
      ! Low side cell:
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
         CASE(IBM_FTYPE_RGGAS) ! Regular cell
         DPVOL(I,J+1+ISIDE,K)=DPVOL(I,J+1+ISIDE,K)+FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF
         ! +ve or -ve dot
         DO N=1,N_TOTAL_SCALARS
         DEL_RHO_D_DEL_Z(I,J+1+ISIDE,K,N)=DEL_RHO_D_DEL_Z(I,J+1+ISIDE,K,N)+FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)*AF
         ENDDO
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF !+/- dot
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)= &
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)+FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(1:N_TOTAL_SCALARS)*AF
         END SELECT
      ENDDO
   CASE(KAXIS)
      AF = DX(I)*DY(J)
      ! H_RHO_D_DZDN
      DO N=1,N_TOTAL_SCALARS
         CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
         IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)
      ENDDO
      ! Add contribution to DP:
      ! Low side cell:
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
         CASE(IBM_FTYPE_RGGAS) ! Regular cell
         DPVOL(I,J,K+1+ISIDE)=DPVOL(I,J,K+1+ISIDE)+FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF
         ! +ve or -ve dot
         DO N=1,N_TOTAL_SCALARS
         DEL_RHO_D_DEL_Z(I,J,K+1+ISIDE,N)=DEL_RHO_D_DEL_Z(I,J,K+1+ISIDE,N)+FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)*AF
         ENDDO
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell
         ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
         IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE
         JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
         CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)+FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF !+/- dot
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)= &
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)+FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(1:N_TOTAL_SCALARS)*AF
         END SELECT
      ENDDO
   END SELECT
ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   ! Note: for cut-faces open boundaries are dealt with below in external BC loops:
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF = CUT_FACE(ICF)%AREA(IFACE)
      ! H_RHO_D_DZDN
      TMP_G = CUT_FACE(ICF)%TMP_FACE(IFACE)
      DO N=1,N_TOTAL_SCALARS
         CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
         CUT_FACE(ICF)%H_RHO_D_DZDN(N,IFACE) = H_S*CUT_FACE(ICF)%RHO_D_DZDN(N,IFACE)
      ENDDO
      ! Add to divergence integral of surrounding cut-cells:
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
         ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
         IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE
         JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
         CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC)+FCT*SUM(CUT_FACE(ICF)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS,IFACE))*AF !+/- dot
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)= &
         CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC)+FCT*CUT_FACE(ICF)%RHO_D_DZDN(1:N_TOTAL_SCALARS,IFACE)*AF
         END SELECT
      ENDDO
   ENDDO ! IFACE
ENDDO ! ICF


! Now define diffussive heat flux components in Boundaries:
! CFACES:
ISIDE=-1
CFACE_LOOP : DO ICF=1,N_CFACE_CELLS
   CFA => CFACE(ICF)
   IND1 = CFA%CUT_FACE_IND1;                         IND2 = CFA%CUT_FACE_IND2
   ICC  = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2);  JCC  = CUT_FACE(IND1)%CELL_LIST(3,LOW_IND,IND2)
   ! H_RHO_D_DZDN
   UN_P =  PRFCT*CFA%ONE_D%U_NORMAL + (1._EB-PRFCT)*CFA%ONE_D%U_NORMAL_S
   TMP_G = CFA%ONE_D%TMP_F
   IF (UN_P>0._EB) TMP_G = CFA%ONE_D%TMP_G
   DO N=1,N_TOTAL_SCALARS
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      CUT_FACE(IND1)%H_RHO_D_DZDN(N,IND2) = H_S*CFA%ONE_D%RHO_D_DZDN_F(N)
   ENDDO
   ! Add diffusive mass flux enthalpy contribution to cut-cell thermo divg:
   CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) - SUM(CUT_FACE(IND1)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS,IND2))*CFA%AREA
   CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC) = &
   CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC) - CFA%ONE_D%RHO_D_DZDN_F(1:N_TOTAL_SCALARS)*CFA%AREA
ENDDO CFACE_LOOP

! Domain boundaries:
SPECIES_LOOP2: DO N=1,N_TOTAL_SCALARS

   ! IAXIS faces:
   X1AXIS = IAXIS
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      I  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(IAXIS)
      J  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(JAXIS)
      K  = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(KAXIS)
      WC => WALL(IW)
      UN_P = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
      TMP_G = WC%ONE_D%TMP_F
      IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY .AND. UN_P>0._EB) TMP_G = WC%ONE_D%TMP_G
      ! H_RHO_D_DZDN
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      IBM_REGFACE_IAXIS_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N)

      ! Add H_RHO_D_DZDN dot n to corresponding cell DP:
      AF = DY(J)*DZ(K)
      SELECT CASE(WC%ONE_D%IOR)
      CASE(-IAXIS) ! Low side cell. Add to int(DEL_RHO_D_DEL_Z)dv in FV form:
      IF (.NOT.IBM_REGFACE_IAXIS_Z(IFACE)%DO_LO_IND) CYCLE
      DPVOL(I  ,J,K)             =             DPVOL(I  ,J,K) + IBM_REGFACE_IAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! +ve dot
      DEL_RHO_D_DEL_Z(I  ,J,K,N) = DEL_RHO_D_DEL_Z(I  ,J,K,N) + IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N)   * AF ! +ve dot
      CASE( IAXIS) ! High side cell.
      IF (.NOT.IBM_REGFACE_IAXIS_Z(IFACE)%DO_HI_IND) CYCLE
      DPVOL(I+1,J,K)             =             DPVOL(I+1,J,K) - IBM_REGFACE_IAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! -ve dot
      DEL_RHO_D_DEL_Z(I+1,J,K,N) = DEL_RHO_D_DEL_Z(I+1,J,K,N) - IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N)   * AF ! -ve dot
      END SELECT
   ENDDO

   ! JAXIS faces:
   X1AXIS = JAXIS
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      I  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(IAXIS)
      J  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(JAXIS)
      K  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(KAXIS)
      WC => WALL(IW)
      UN_P = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
      TMP_G = WC%ONE_D%TMP_F
      IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY .AND. UN_P>0._EB) TMP_G = WC%ONE_D%TMP_G
      ! H_RHO_D_DZDN
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      IBM_REGFACE_JAXIS_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N)

      ! Add H_RHO_D_DZDN dot n to corresponding cell DP:
      AF = DX(I)*DZ(K)
      SELECT CASE(WC%ONE_D%IOR)
      CASE(-JAXIS) ! Low side cell. Add to int(DEL_RHO_D_DEL_Z)dv in FV form:
      IF (.NOT.IBM_REGFACE_JAXIS_Z(IFACE)%DO_LO_IND) CYCLE
      DPVOL(I,J  ,K)             =             DPVOL(I,J  ,K) + IBM_REGFACE_JAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! +ve dot
      DEL_RHO_D_DEL_Z(I,J  ,K,N) = DEL_RHO_D_DEL_Z(I,J  ,K,N) + IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N)   * AF ! +ve dot
      CASE( JAXIS) ! High side cell.
      IF (.NOT.IBM_REGFACE_JAXIS_Z(IFACE)%DO_HI_IND) CYCLE
      DPVOL(I,J+1,K)             =             DPVOL(I,J+1,K) - IBM_REGFACE_JAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! -ve dot
      DEL_RHO_D_DEL_Z(I,J+1,K,N) = DEL_RHO_D_DEL_Z(I,J+1,K,N) - IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N)   * AF ! -ve dot
      END SELECT
   ENDDO

   ! KAXIS faces:
   X1AXIS = KAXIS
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      I  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(IAXIS)
      J  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(JAXIS)
      K  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(KAXIS)
      WC => WALL(IW)
      UN_P = PRFCT*WC%ONE_D%U_NORMAL + (1._EB-PRFCT)*WC%ONE_D%U_NORMAL_S
      TMP_G = WC%ONE_D%TMP_F
      IF (WC%BOUNDARY_TYPE==SOLID_BOUNDARY .AND. UN_P>0._EB) TMP_G = WC%ONE_D%TMP_G
      ! H_RHO_D_DZDN
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      IBM_REGFACE_KAXIS_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N)

      ! Add H_RHO_D_DZDN dot n to corresponding cell DP:
      AF = DX(I)*DY(J)
      SELECT CASE(WC%ONE_D%IOR)
      CASE(-KAXIS) ! Low side cell. Add to int(DEL_RHO_D_DEL_Z)dv in FV form:
      IF (.NOT.IBM_REGFACE_KAXIS_Z(IFACE)%DO_LO_IND) CYCLE
      DPVOL(I,J,K  )             =             DPVOL(I,J,K  ) + IBM_REGFACE_KAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! +ve dot
      DEL_RHO_D_DEL_Z(I,J,K  ,N) = DEL_RHO_D_DEL_Z(I,J,K  ,N) + IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N)   * AF ! +ve dot
      CASE( KAXIS) ! High side cell.
      IF (.NOT.IBM_REGFACE_KAXIS_Z(IFACE)%DO_HI_IND) CYCLE
      DPVOL(I,J,K+1)             =             DPVOL(I,J,K+1) - IBM_REGFACE_KAXIS_Z(IFACE)%H_RHO_D_DZDN(N) * AF ! -ve dot
      DEL_RHO_D_DEL_Z(I,J,K+1,N) = DEL_RHO_D_DEL_Z(I,J,K+1,N) - IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N)   * AF ! -ve dot
      END SELECT
   ENDDO

ENDDO SPECIES_LOOP2

! Regular faces connecting gasphase- cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   TMP_G  = IBM_RCFACE_Z(IFACE)%TMP_FACE

   WC => WALL(IW)
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   IOR = WC%ONE_D%IOR
   ! H_RHO_D_DZDN
   DO N=1,N_TOTAL_SCALARS
      CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
      IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(N) = H_S*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)
   ENDDO
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      AF = DY(J)*DZ(K)
   CASE(JAXIS)
      AF = DX(I)*DZ(K)
   CASE(KAXIS)
      AF = DX(I)*DY(J)
   END SELECT
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
   SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
   CASE(IBM_FTYPE_RGGAS) ! Regular cell
   DPVOL(IIG,JJG,KKG)=DPVOL(IIG,JJG,KKG)+FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF ! +ve or -ve dot
   DO N=1,N_TOTAL_SCALARS
      DEL_RHO_D_DEL_Z(IIG,JJG,KKG,N)=DEL_RHO_D_DEL_Z(IIG,JJG,KKG,N)+FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N)*AF
   ENDDO
   CASE(IBM_FTYPE_CFGAS) ! Cut-cell
   ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
   JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
   CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + FCT*SUM(IBM_RCFACE_Z(IFACE)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS))*AF !+/- dot
   CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC) = &
   CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC) + FCT*IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(1:N_TOTAL_SCALARS) * AF
   END SELECT
ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   ! Note: for cut-faces open boundaries are dealt with below in external BC loops:
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF = CUT_FACE(ICF)%AREA(IFACE)
      ! H_RHO_D_DZDN
      TMP_G = CUT_FACE(ICF)%TMP_FACE(IFACE)
      DO N=1,N_TOTAL_SCALARS
         CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP_G,H_S)
         CUT_FACE(ICF)%H_RHO_D_DZDN(N,IFACE) = H_S*CUT_FACE(ICF)%RHO_D_DZDN(N,IFACE)
      ENDDO
      ! Add to divergence integral of surrounding cut-cells:
      FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
      SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
      CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
      ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
      JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
      CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + FCT*SUM(CUT_FACE(ICF)%H_RHO_D_DZDN(1:N_TOTAL_SCALARS,IFACE)) * AF !+/- dot
      CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC) = &
      CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(1:N_TOTAL_SCALARS,JCC) + FCT*CUT_FACE(ICF)%RHO_D_DZDN(1:N_TOTAL_SCALARS,IFACE)*AF
      END SELECT
   ENDDO ! IFACE
ENDDO ! ICF

RETURN
END SUBROUTINE CCREGION_DIFFUSIVE_HEAT_FLUXES

! ----------------------- CCREGION_CONDUCTION_HEAT_FLUX --------------------------

SUBROUTINE CCREGION_CONDUCTION_HEAT_FLUX

INTEGER :: IIG, JJG, KKG, IOR
REAL(EB):: KPDTDN=0._EB,KPV(-1:0)=0._EB

! IAXIS faces:
X1AXIS = IAXIS
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)

   IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

   I     = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(IAXIS)
   J     = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(JAXIS)
   K     = IBM_REGFACE_IAXIS_Z(IFACE)%IJK(KAXIS)

   ! K*DTDN:
   TMPV(-1:0)  = TMP(I:I+1,J,K)
   ! KP on low-high side cells:
   DO ISIDE=-1,0
      ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
      CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MU(I+1+ISIDE,J,K),&
                                             MU_DNS(I+1+ISIDE,J,K),TMPV(ISIDE),KPV(ISIDE))
   ENDDO
   KPDTDN = 0.5_EB*(KPV(-1)+KPV(0)) * (TMPV(0)-TMPV(-1)) / DX(I)

   ! Add K*DTDN dot n to corresponding cell DP:
   AF = DY(J)*DZ(K)
   IF(IBM_REGFACE_IAXIS_Z(IFACE)%DO_LO_IND) DPVOL(I  ,J,K) = DPVOL(I  ,J,K) + KPDTDN * AF ! +ve dot
   IF(IBM_REGFACE_IAXIS_Z(IFACE)%DO_HI_IND) DPVOL(I+1,J,K) = DPVOL(I+1,J,K) - KPDTDN * AF ! -ve dot
ENDDO

! JAXIS faces:
X1AXIS = JAXIS
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)

   IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

   I  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_JAXIS_Z(IFACE)%IJK(KAXIS)

   ! K*DTDN:
   TMPV(-1:0)  = TMP(I,J:J+1,K)
   ! KP on low-high side cells:
   DO ISIDE=-1,0
      ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
      CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MU(I,J+1+ISIDE,K),&
                                             MU_DNS(I,J+1+ISIDE,K),TMPV(ISIDE),KPV(ISIDE))
   ENDDO
   KPDTDN = 0.5_EB*(KPV(-1)+KPV(0)) * (TMPV(0)-TMPV(-1)) / DY(J)

   ! Add K*DTDN dot n to corresponding cell DP:
   AF = DX(I)*DZ(K)
   IF(IBM_REGFACE_JAXIS_Z(IFACE)%DO_LO_IND) DPVOL(I,J  ,K) = DPVOL(I,J  ,K) + KPDTDN * AF ! +ve dot
   IF(IBM_REGFACE_JAXIS_Z(IFACE)%DO_HI_IND) DPVOL(I,J+1,K) = DPVOL(I,J+1,K) - KPDTDN * AF ! -ve dot
ENDDO

! KAXIS faces:
X1AXIS = KAXIS
DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)

   IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

   I  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(IAXIS)
   J  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(JAXIS)
   K  = IBM_REGFACE_KAXIS_Z(IFACE)%IJK(KAXIS)

   ! K*DTDN:
   TMPV(-1:0)  = TMP(I,J,K:K+1)
   ! KP on low-high side cells:
   DO ISIDE=-1,0
      ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
      CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MU(I,J,K+1+ISIDE),&
                                             MU_DNS(I,J,K+1+ISIDE),TMPV(ISIDE),KPV(ISIDE))
   ENDDO
   KPDTDN = 0.5_EB*(KPV(-1)+KPV(0)) * (TMPV(0)-TMPV(-1)) / DZ(K)

   ! Add K*DTDN dot n to corresponding cell DP:
   AF = DX(I)*DY(J)
   IF(IBM_REGFACE_KAXIS_Z(IFACE)%DO_LO_IND) DPVOL(I,J,K  ) = DPVOL(I,J,K  ) + KPDTDN * AF ! +ve dot
   IF(IBM_REGFACE_KAXIS_Z(IFACE)%DO_HI_IND) DPVOL(I,J,K+1) = DPVOL(I,J,K+1) - KPDTDN * AF ! -ve dot
ENDDO


! Regular faces connecting gasphase - cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z

   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

   I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
   J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
   K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)

   SELECT CASE(X1AXIS)
      CASE(IAXIS)
         AF = DY(J)*DZ(K)
         X1F= MESHES(NM)%X(I)
         IDX = 1._EB / ( IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                         IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND) )
         ! Linear interpolation coefficients:
         CCM1 = IDX*(IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND)-X1F)
         CCP1 = IDX*(X1F -IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND))

         TMPV(-1:0)  = TMP(I:I+1,J,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I+1+ISIDE,J,K,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  &
                      PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
               (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            ! KP on low-high side cells:
            CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MU(I+1+ISIDE,J,K),&
                                                   MU_DNS(I+1+ISIDE,J,K),TMPV(ISIDE),KPV(ISIDE))
         ENDDO

         KPDTDN = (CCM1*KPV(-1)+CCP1*KPV(0)) * (TMPV(0)-TMPV(-1)) * IDX

         ! Add contribution to DP:
         ! Low side cell:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I+1+ISIDE,J,K) = DPVOL(I+1+ISIDE,J,K) + FCT*KPDTDN * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + FCT*KPDTDN * AF ! +ve or -ve dot
            END SELECT
         ENDDO

      CASE(JAXIS)
         AF = DX(I)*DZ(K)
         X1F= MESHES(NM)%Y(J)
         IDX = 1._EB / ( IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                         IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND) )
         ! Linear interpolation coefficients:
         CCM1 = IDX*(IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND)-X1F)
         CCP1 = IDX*(X1F -IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND))

         TMPV(-1:0)  = TMP(I,J:J+1,K)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J+1+ISIDE,K,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  &
                      PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
               (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            ! KP on low-high side cells:
            CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MU(I,J+1+ISIDE,K),&
                                                   MU_DNS(I,J+1+ISIDE,K),TMPV(ISIDE),KPV(ISIDE))
         ENDDO

         KPDTDN = (CCM1*KPV(-1)+CCP1*KPV(0)) * (TMPV(0)-TMPV(-1)) * IDX

         ! Add contribution to DP:
         ! Low side cell:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I,J+1+ISIDE,K) = DPVOL(I,J+1+ISIDE,K) + FCT*KPDTDN * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + FCT*KPDTDN * AF ! +ve or -ve dot
            END SELECT
         ENDDO

      CASE(KAXIS)
         AF = DX(I)*DY(J)
         X1F= MESHES(NM)%Z(K)
         IDX = 1._EB / ( IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                         IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND) )
         ! Linear interpolation coefficients:
         CCM1 = IDX*(IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND)-X1F)
         CCP1 = IDX*(X1F -IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND))

         TMPV(-1:0)  = TMP(I,J,K:K+1)
         DO ISIDE=-1,0
            ZZ_GET = 0._EB
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K+1+ISIDE,1:N_TRACKED_SPECIES)
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               ZZ_GET(1:N_TRACKED_SPECIES) =  &
                      PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
               (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            END SELECT
            ! KP on low-high side cells:
            CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MU(I,J,K+1+ISIDE),&
                                                   MU_DNS(I,J,K+1+ISIDE),TMPV(ISIDE),KPV(ISIDE))
         ENDDO

         KPDTDN = (CCM1*KPV(-1)+CCP1*KPV(0)) * (TMPV(0)-TMPV(-1)) * IDX

         ! Add contribution to DP:
         ! Low side cell:
         DO ISIDE=-1,0
            FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
            SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
            CASE(IBM_FTYPE_RGGAS) ! Regular cell
               DPVOL(I,J,K+1+ISIDE) = DPVOL(I,J,K+1+ISIDE) + FCT*KPDTDN * AF ! +ve or -ve dot
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell
               ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
               IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
               JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
               CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + FCT*KPDTDN * AF ! +ve or -ve dot
            END SELECT
         ENDDO

   ENDSELECT

ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = CUT_FACE(ICF)%IWC
   ! Note: for cut-faces open boundaries are dealt with below in external BC loops:
   IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                           WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   SELECT CASE(X1AXIS)
   CASE(IAXIS)
      MUV(-1:0)    = MU(I:I+1,J,K)
      MU_DNSV(-1:0)= MU_DNS(I:I+1,J,K)
   CASE(JAXIS)
      MUV(-1:0)    = MU(I,J:J+1,K)
      MU_DNSV(-1:0)= MU_DNS(I,J:J+1,K)
   CASE(KAXIS)
      MUV(-1:0)    = MU(I,J,K:K+1)
      MU_DNSV(-1:0)= MU_DNS(I,J,K:K+1)
   END SELECT
   DO IFACE=1,CUT_FACE(ICF)%NFACE
      AF = CUT_FACE(ICF)%AREA(IFACE)
      X1F= CUT_FACE(ICF)%XYZCEN(X1AXIS,IFACE)
      IDX= 1._EB/ ( CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE) - &
                    CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE) )
      CCM1= IDX*(CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE)-X1F)
      CCP1= IDX*(X1F-CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE))
      ! Interpolate D_Z to the face, linear interpolation:
      TMPV(-1:0)  = -1._EB
      DO ISIDE=-1,0
         ZZ_GET = 0._EB
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
            ZZ_GET(1:N_TRACKED_SPECIES) =  &
                   PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
            (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
         END SELECT
         ! KP on low-high side cells:
         CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MUV(ISIDE),MU_DNSV(ISIDE),TMPV(ISIDE),KPV(ISIDE))
      ENDDO
      KPDTDN = (CCM1*KPV(-1)+CCP1*KPV(0)) * (TMPV(0)-TMPV(-1)) * IDX
      ! Add to divergence integral of surrounding cut-cells:
      DO ISIDE=-1,0
         FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + FCT*KPDTDN * AF ! +ve or -ve dot
         END SELECT
      ENDDO
   ENDDO ! IFACE
ENDDO ! ICF

! Now do Boundary conditions for Conductive Heat Flux:
! IAXIS faces:
X1AXIS = IAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE ! Already done on previous loops.
   WC => WALL(IW)
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   AF  = DY(JJG)*DZ(KKG)
   ! Q_LEAK accounts for enthalpy moving through leakage paths
   DPVOL(IIG,JJG,KKG) = DPVOL(IIG,JJG,KKG) - ( WC%ONE_D%Q_CON_F ) * AF  + WC%Q_LEAK * (DX(IIG)*DY(JJG)*DZ(KKG))
ENDDO

! JAXIS faces:
X1AXIS = JAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE ! Already done on previous loops.
   WC => WALL(IW)
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   AF  = DX(IIG)*DZ(KKG)
   ! Q_LEAK accounts for enthalpy moving through leakage paths
   DPVOL(IIG,JJG,KKG) = DPVOL(IIG,JJG,KKG) - ( WC%ONE_D%Q_CON_F ) * AF  + WC%Q_LEAK * (DX(IIG)*DY(JJG)*DZ(KKG))
ENDDO

! KAXIS faces:
X1AXIS = KAXIS
DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
   IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE ! Already done on previous loops.
   WC => WALL(IW)
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   AF  = DX(IIG)*DY(JJG)
   ! Q_LEAK accounts for enthalpy moving through leakage paths
   DPVOL(IIG,JJG,KKG) = DPVOL(IIG,JJG,KKG) - ( WC%ONE_D%Q_CON_F ) * AF  + WC%Q_LEAK * (DX(IIG)*DY(JJG)*DZ(KKG))
ENDDO

! Regular faces connecting gasphase - cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z
   IW = IBM_RCFACE_Z(IFACE)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
   X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
   WC => WALL(IW)
   IIG = WC%ONE_D%IIG
   JJG = WC%ONE_D%JJG
   KKG = WC%ONE_D%KKG
   IOR = WC%ONE_D%IOR
   SELECT CASE(X1AXIS)
       CASE(IAXIS)
          AF=DY(JJG)*DZ(KKG)
       CASE(JAXIS)
          AF=DX(IIG)*DZ(KKG)
       CASE(KAXIS)
          AF=DX(IIG)*DY(JJG)
   END SELECT
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
   CASE(IBM_FTYPE_RGGAS) ! Regular cell.
      ! Q_LEAK accounts for enthalpy moving through leakage paths
      DPVOL(IIG,JJG,KKG) = DPVOL(IIG,JJG,KKG) - ( WC%ONE_D%Q_CON_F ) * AF  + WC%Q_LEAK * (DX(IIG)*DY(JJG)*DZ(KKG))
   CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
      ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
      IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
      JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
      CUT_CELL(ICC)%DVOL(JCC) = &
      CUT_CELL(ICC)%DVOL(JCC) - ( WC%ONE_D%Q_CON_F ) * AF + WC%Q_LEAK * CUT_CELL(ICC)%VOLUME(JCC) ! Qconf +ve sign is
                                                                                                  ! outwards of cut-cell.
   END SELECT
ENDDO

! GASPHASE cut-faces:
DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
   IW = MESHES(NM)%CUT_FACE(ICF)%IWC
   IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
       WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
       WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE

   I = CUT_FACE(ICF)%IJK(IAXIS)
   J = CUT_FACE(ICF)%IJK(JAXIS)
   K = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
   WC => WALL(IW)
   IOR = WC%ONE_D%IOR
   ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
   !                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
   ISIDE = -1 + (SIGN(1,IOR)+1) / 2
   ! External boundary cut-cells of type OPEN_BOUNDARY:
   GASBOUND_IF : IF (WALL(IW)%BOUNDARY_TYPE==OPEN_BOUNDARY) THEN
      FCT = -REAL(2*ISIDE+1,EB) ! Factor to set +ve or -ve sign of dot with normal outside.
      DO IFACE=1,CUT_FACE(ICF)%NFACE
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            AF = CUT_FACE(ICF)%AREA(IFACE)
            X1F= CUT_FACE(ICF)%XYZCEN(X1AXIS,IFACE)
            IF (WC%ONE_D%IOR > 0) THEN
               IDX= 0.5_EB/(CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE)-X1F) ! Assumes DX twice the distance from WALL_CELL
                                                                      ! to internal cut-cell centroid.
            ELSE
               IDX= 0.5_EB/(X1F-CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE))
            ENDIF
            SELECT CASE(X1AXIS)
            CASE(IAXIS)
               MUV(-1:0)    =     MU(I:I+1,J,K)
               MU_DNSV(-1:0)= MU_DNS(I:I+1,J,K)
               KPV(-1:0)    =     MU(I:I+1,J,K)*CPOPR
               TMPV(-1:0)   =    TMP(I:I+1,J,K)
            CASE(JAXIS)
               MUV(-1:0)    =     MU(I,J:J+1,K)
               MU_DNSV(-1:0)= MU_DNS(I,J:J+1,K)
               KPV(-1:0)    =     MU(I,J:J+1,K)*CPOPR
               TMPV(-1:0)   =    TMP(I,J:J+1,K)
            CASE(KAXIS)
               MUV(-1:0)    =     MU(I,J,K:K+1)
               MU_DNSV(-1:0)= MU_DNS(I,J,K:K+1)
               KPV(-1:0)    =     MU(I,J,K:K+1)*CPOPR
               TMPV(-1:0)   =    TMP(I,J,K:K+1)
            END SELECT
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
            ZZ_GET(1:N_TRACKED_SPECIES) =  PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                                    (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            CALL GET_CCREGION_CELL_CONDUCTIVITY(ZZ_GET,MUV(ISIDE),MU_DNSV(ISIDE),TMPV(ISIDE),KPV(ISIDE))
            KPDTDN = 0.5_EB*(KPV(-1)+KPV(0)) * (TMPV(0)-TMPV(-1)) * IDX
            CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC) + FCT*KPDTDN * AF ! +ve or -ve dot
         END SELECT
      ENDDO

   ELSE
      ! Other boundary conditions:
      DO IFACE=1,CUT_FACE(ICF)%NFACE
         AF = CUT_FACE(ICF)%AREA(IFACE)
         SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
         CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
            ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
            IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE ! Cut-cell is guard-cell cc.
            JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
            CUT_CELL(ICC)%DVOL(JCC) = &
            CUT_CELL(ICC)%DVOL(JCC) - ( WC%ONE_D%Q_CON_F ) * AF + WC%Q_LEAK * CUT_CELL(ICC)%VOLUME(JCC) ! Qconf +ve sign
                                                                                                        ! is outwards of cut-cell.
         END SELECT
      ENDDO
   ENDIF GASBOUND_IF
ENDDO

! INBOUNDARY cut-faces, loop on CFACE to add BC defined at SOLID phase:
IF (PREDICTOR) THEN
  DO ICF=1,N_CFACE_CELLS
     CFA  => CFACE(ICF)
     IND1 = CFA%CUT_FACE_IND1;                         IND2 = CFA%CUT_FACE_IND2
     ICC  = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2);  JCC  = CUT_FACE(IND1)%CELL_LIST(3,LOW_IND,IND2)
     CUT_CELL(ICC)%DVOL(JCC)=CUT_CELL(ICC)%DVOL(JCC)-( CFA%ONE_D%Q_CON_F ) * CUT_FACE(IND1)%AREA(IND2) ! QCONF(+) into solid.
  ENDDO
ELSE
  DO ICF=1,N_CFACE_CELLS
     CFA  => CFACE(ICF)
     IND1 = CFA%CUT_FACE_IND1;                         IND2 = CFA%CUT_FACE_IND2
     ICC  = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2);  JCC  = CUT_FACE(IND1)%CELL_LIST(3,LOW_IND,IND2)
     CUT_CELL(ICC)%DVOL(JCC) = CUT_CELL(ICC)%DVOL(JCC)-( CFA%ONE_D%Q_CON_F ) * CUT_FACE(IND1)%AREA(IND2) ! QCONF(+) into solid.
  ENDDO
ENDIF

RETURN
END SUBROUTINE CCREGION_CONDUCTION_HEAT_FLUX


END SUBROUTINE CCREGION_DIVERGENCE_PART_1

! ------------------------ GET_CCREGION_CELL_DIFFUSIVITY -------------------------

SUBROUTINE GET_CCREGION_CELL_DIFFUSIVITY(RHO_CELL,D_Z_N,MU_CELL,MU_DNS_CELL,TMP_CELL,D_Z_TEMP)

USE MATH_FUNCTIONS, ONLY: INTERPOLATE1D_UNIFORM
USE MANUFACTURED_SOLUTIONS, ONLY: DIFF_MMS

REAL(EB), INTENT(IN) :: RHO_CELL,D_Z_N(0:5000),MU_CELL,MU_DNS_CELL,TMP_CELL
REAL(EB), INTENT(OUT):: D_Z_TEMP

REAL(EB) :: D_Z_TEMP_DNS

SELECT CASE(SIM_MODE)
CASE(LES_MODE)
   CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,TMP_CELL,D_Z_TEMP_DNS)
   D_Z_TEMP = D_Z_TEMP_DNS + MAX(0._EB,MU_CELL-MU_DNS_CELL)*RSC/RHO_CELL
CASE(DNS_MODE)
   IF(PERIODIC_TEST==7) THEN
      D_Z_TEMP = DIFF_MMS / RHO_CELL
   ELSE
      CALL INTERPOLATE1D_UNIFORM(LBOUND(D_Z_N,1),D_Z_N,TMP_CELL,D_Z_TEMP)
   ENDIF
CASE DEFAULT
   D_Z_TEMP = MU_CELL*RSC/RHO_CELL ! VLES
END SELECT

RETURN
END SUBROUTINE GET_CCREGION_CELL_DIFFUSIVITY

! ----------------------- GET_CCREGION_CELL_CONDUCTIVITY -------------------------

SUBROUTINE GET_CCREGION_CELL_CONDUCTIVITY(ZZ_CELL,MU_CELL,MU_DNS_CELL,TMP_CELL,KP_CELL)

USE PHYSICAL_FUNCTIONS, ONLY: GET_CONDUCTIVITY,GET_SPECIFIC_HEAT

REAL(EB), INTENT(IN)  :: ZZ_CELL(1:N_TRACKED_SPECIES),MU_CELL,MU_DNS_CELL,TMP_CELL
REAL(EB), INTENT(OUT) :: KP_CELL

! Local Vars:
REAL(EB) :: CP_CELL

IF (SIM_MODE==DNS_MODE .OR. SIM_MODE==LES_MODE) THEN
   CALL GET_CONDUCTIVITY(ZZ_CELL,KP_CELL,TMP_CELL)
   IF (SIM_MODE==LES_MODE) THEN
      IF (.NOT.CONSTANT_SPECIFIC_HEAT_RATIO) THEN
         CALL GET_SPECIFIC_HEAT(ZZ_CELL,CP_CELL,TMP_CELL)
         KP_CELL = KP_CELL + MAX(0._EB,MU_CELL-MU_DNS_CELL)*CP_CELL*RPR
      ELSE
         KP_CELL = KP_CELL + MAX(0._EB,MU_CELL-MU_DNS_CELL)*CPOPR
      ENDIF
   ENDIF
ELSE ! VLES
   KP_CELL = MU_CELL*CPOPR
ENDIF

RETURN
END SUBROUTINE GET_CCREGION_CELL_CONDUCTIVITY

! ----------------------- CCREGION_DIFFUSIVE_MASS_FLUXES -------------------------

SUBROUTINE CCREGION_DIFFUSIVE_MASS_FLUXES(NM)

INTEGER, INTENT(IN) :: NM

! NOTE: this routine assumes POINT_TO_MESH(NM) has been previously called.

! Local Variables:
INTEGER :: N,I,J,K,X1AXIS,ISIDE,IFACE,ICC,JCC,ICF
REAL(EB), POINTER, DIMENSION(:,:,:) :: RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
REAL(EB) :: D_Z_N(0:5000),CCM1,CCP1,IDX,DIFF_FACE,D_Z_TEMP(-1:0),MUV(-1:0),MU_DNSV(-1:0), &
            RHOPV(-1:0),TMPV(-1:0),ZZPV(-1:0),X1F,PRFCT
REAL(EB), ALLOCATABLE, DIMENSION(:) :: ZZ_GET,RHO_D_DZDN_GET
INTEGER,  ALLOCATABLE, DIMENSION(:) :: N_ZZ_MAX_V
INTEGER :: N_LOOKUP, IW
REAL(EB) :: RHO_D_DZDN, ZZ_FACE, TMP_FACE
TYPE(CFACE_TYPE), POINTER :: CFA=>NULL()

SELECT CASE(PREDICTOR)
   CASE(.TRUE.)
      ZZP => ZZS
      RHOP => RHOS
      PRFCT = 0._EB ! Use star cut-cell quantities.
   CASE(.FALSE.)
      ZZP => ZZ
      RHOP => RHO
      PRFCT = 1._EB ! Use end of step cut-cell quantities.
END SELECT

ALLOCATE(ZZ_GET(N_TRACKED_SPECIES),RHO_D_DZDN_GET(N_TRACKED_SPECIES))

! Define species index of max CFACE mass fraction.
ALLOCATE(N_ZZ_MAX_V(N_CFACE_CELLS))
DO ICF=1,N_CFACE_CELLS
   N_ZZ_MAX_V(ICF)=MAXLOC(CFACE(ICF)%ONE_D%ZZ_F(1:N_TRACKED_SPECIES),1)
ENDDO

! 1. Diffusive Heat flux = - Grad dot (h_s rho D Grad Z_n):
! In FV form: use faces to add corresponding face integral terms, for face k
! (sum_a{h_{s,a} rho D_a Grad z_a) dot \hat{n}_k A_k, where \hat{n}_k is the versor outside of cell
! at face k.
DIFFUSIVE_FLUX_LOOP: DO N=1,N_TOTAL_SCALARS

   ! Diffusivity lookup table for species N:
   N_LOOKUP = N
   D_Z_N(:) = D_Z(:,N_LOOKUP)

   ! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z

      IW = IBM_RCFACE_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

      I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
      J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
      K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
      X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)

      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            X1F= MESHES(NM)%X(I)
            IDX = 1._EB / ( IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                            IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND) )
            ! Linear interpolation coefficients:
            CCM1 = IDX*(IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND)-X1F)
            CCP1 = IDX*(X1F -IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND))

            TMPV(-1:0)  = TMP(I:I+1,J,K)
            RHOPV(-1:0) = RHOP(I:I+1,J,K)
            ZZPV(-1:0)  = ZZP(I:I+1,J,K,N)
            DO ISIDE=-1,0
               SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
               CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
                  ! TMPV(ISIDE) = TMPV(ISIDE)
               CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                  ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
                  JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
                  TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
                  RHOPV(ISIDE)=        PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
                  ZZPV(ISIDE) =        PRFCT *CUT_CELL(ICC)%ZZ(N,JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
               END SELECT
               CALL GET_CCREGION_CELL_DIFFUSIVITY(RHOPV(ISIDE),D_Z_N,MU(I+1+ISIDE,J,K),&
                                                MU_DNS(I+1+ISIDE,J,K),TMPV(ISIDE),D_Z_TEMP(ISIDE))
            ENDDO

         CASE(JAXIS)
            X1F= MESHES(NM)%Y(J)
            IDX = 1._EB / ( IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                            IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND) )
            ! Linear interpolation coefficients:
            CCM1 = IDX*(IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND)-X1F)
            CCP1 = IDX*(X1F -IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND))

            TMPV(-1:0)  = TMP(I,J:J+1,K)
            RHOPV(-1:0) = RHOP(I,J:J+1,K)
            ZZPV(-1:0)  = ZZP(I,J:J+1,K,N)
            DO ISIDE=-1,0
               SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
               CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
                  ! TMPV(ISIDE) = TMPV(ISIDE)
                  ! RHOPV(ISIDE)= RHOPV(ISIDE)
               CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                  ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
                  JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
                  TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
                  RHOPV(ISIDE)=        PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
                  ZZPV(ISIDE) =        PRFCT *CUT_CELL(ICC)%ZZ(N,JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
               END SELECT
               CALL GET_CCREGION_CELL_DIFFUSIVITY(RHOPV(ISIDE),D_Z_N,MU(I,J+1+ISIDE,K),&
                                                MU_DNS(I,J+1+ISIDE,K),TMPV(ISIDE),D_Z_TEMP(ISIDE))
            ENDDO

         CASE(KAXIS)
            X1F= MESHES(NM)%Z(K)
            IDX = 1._EB / ( IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                            IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND) )
            ! Linear interpolation coefficients:
            CCM1 = IDX*(IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND)-X1F)
            CCP1 = IDX*(X1F -IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,LOW_IND))

            TMPV(-1:0)  = TMP(I,J,K:K+1)
            RHOPV(-1:0) = RHOP(I,J,K:K+1)
            ZZPV(-1:0)  = ZZP(I,J,K:K+1,N)
            DO ISIDE=-1,0
               SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
               CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
                  ! TMPV(ISIDE) = TMPV(ISIDE)
                  ! RHOPV(ISIDE)= RHOPV(ISIDE)
               CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                  ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
                  JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
                  TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
                  RHOPV(ISIDE)=        PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
                  ZZPV(ISIDE) =        PRFCT *CUT_CELL(ICC)%ZZ(N,JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
               END SELECT
               CALL GET_CCREGION_CELL_DIFFUSIVITY(RHOPV(ISIDE),D_Z_N,MU(I,J,K+1+ISIDE),&
                                                MU_DNS(I,J,K+1+ISIDE),TMPV(ISIDE),D_Z_TEMP(ISIDE))
            ENDDO

      ENDSELECT

      ! One Term defined flux:
      DIFF_FACE = CCM1*RHOPV(-1)*D_Z_TEMP(-1) + CCP1*RHOPV(0)*D_Z_TEMP(0)
      IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N) = DIFF_FACE*IDX*(ZZPV(0) - ZZPV(-1) ) ! + rho D_a Grad(Y_a)
      IBM_RCFACE_Z(IFACE)%ZZ_FACE(N) = CCM1*ZZPV(-1) + CCP1*ZZPV(0) ! Linear interpolation of ZZ to the face.
      IBM_RCFACE_Z(IFACE)%TMP_FACE = CCM1*TMPV(-1) + CCP1*TMPV(0)   ! Linear interpolation of Temp to the face.

   ENDDO


   ! GASPHASE cut-faces:
   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
      IW = CUT_FACE(ICF)%IWC
      ! Note: for cut-faces open boundaries are dealt with below in external BC loops:
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      DO IFACE=1,CUT_FACE(ICF)%NFACE

         !AF = CUT_FACE(ICF)%AREA(IFACE)
         X1F= CUT_FACE(ICF)%XYZCEN(X1AXIS,IFACE)
         IDX= 1._EB/ ( CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE) - &
                       CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE) )
         CCM1= IDX*(CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE)-X1F)
         CCP1= IDX*(X1F-CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE))

         SELECT CASE (X1AXIS)
         CASE(IAXIS)
            MUV(-1:0)     =     MU(I:I+1,J,K)
            MU_DNSV(-1:0) = MU_DNS(I:I+1,J,K)
         CASE(JAXIS)
            MUV(-1:0)     =     MU(I,J:J+1,K)
            MU_DNSV(-1:0) = MU_DNS(I,J:J+1,K)
         CASE(KAXIS)
            MUV(-1:0)     =     MU(I,J,K:K+1)
            MU_DNSV(-1:0) = MU_DNS(I,J,K:K+1)
         END SELECT

         ! Interpolate D_Z to the face, linear interpolation:
         TMPV(-1:0)  = -1._EB; RHOPV(-1:0) = -1._EB; ZZPV(-1:0)  = -1._EB
         DO ISIDE=-1,0
            SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
               JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
               TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
               RHOPV(ISIDE)=        PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
                             (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
               ZZPV(ISIDE) =        PRFCT *CUT_CELL(ICC)%ZZ(N,JCC) + &
                             (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            CALL GET_CCREGION_CELL_DIFFUSIVITY(RHOPV(ISIDE),D_Z_N,MUV(ISIDE),MU_DNSV(ISIDE),TMPV(ISIDE),D_Z_TEMP(ISIDE))
         ENDDO

         ! One Term defined flux:
         DIFF_FACE = CCM1*RHOPV(-1)*D_Z_TEMP(-1) + CCP1*RHOPV(0)*D_Z_TEMP(0)
         CUT_FACE(ICF)%RHO_D_DZDN(N,IFACE) = DIFF_FACE*IDX*(ZZPV(0) - ZZPV(-1) ) ! rho D_a Grad(Y_a)
         CUT_FACE(ICF)%ZZ_FACE(N,IFACE) = CCM1*ZZPV(-1) + CCP1*ZZPV(0) ! Linear interpolation of ZZ to the face.
         CUT_FACE(ICF)%TMP_FACE(IFACE)  = CCM1*TMPV(-1) + CCP1*TMPV(0) ! Linear interpolation of TMP to the face.

      ENDDO ! IFACE

   ENDDO ! ICF

   ! Now Boundary Conditions:
   ! CFACES:
   ISIDE=-1
   CFACE_LOOP : DO ICF=1,N_CFACE_CELLS
      CFA => CFACE(ICF)
      ! Use external Gas point data for ZZ_G estimation, consistent with CFA%ONE_D%RDN in the finite difference.
      ! Flux fixing done here for CFACEs:
      RHO_D_DZDN = 2._EB*CFA%ONE_D%RHO_D_F(N)*(CFA%ONE_D%ZZ_G(N)-CFA%ONE_D%ZZ_F(N))*CFA%ONE_D%RDN
      IF (N==N_ZZ_MAX_V(ICF)) THEN
         ZZ_GET(1:N_TRACKED_SPECIES) = CFA%ONE_D%ZZ_G(1:N_TRACKED_SPECIES)
         RHO_D_DZDN_GET(1:N_TRACKED_SPECIES) = &
         2._EB*CFA%ONE_D%RHO_D_F(1:N_TRACKED_SPECIES)*( ZZ_GET(1:N_TRACKED_SPECIES) - &
                                                CFA%ONE_D%ZZ_F(1:N_TRACKED_SPECIES))*CFA%ONE_D%RDN
         RHO_D_DZDN = -(SUM(RHO_D_DZDN_GET(1:N_TRACKED_SPECIES))-RHO_D_DZDN)
      ENDIF
      CFA%ONE_D%RHO_D_DZDN_F(N) = RHO_D_DZDN

      ! Now add variables from CFACES to INBOUNDARY cut-faces containers:
      CUT_FACE(CFA%CUT_FACE_IND1)%RHO_D_DZDN(N,CFA%CUT_FACE_IND2) = RHO_D_DZDN
      CUT_FACE(CFA%CUT_FACE_IND1)%ZZ_FACE(N,   CFA%CUT_FACE_IND2) = CFA%ONE_D%ZZ_F(N)
      CUT_FACE(CFA%CUT_FACE_IND1)%TMP_FACE(    CFA%CUT_FACE_IND2) = CFA%ONE_D%TMP_F
   ENDDO CFACE_LOOP

   ! Mesh Boundaries:
   ! Regular Faces:
   ! For Regular Faces connecting regular cells we use the WALL_CELL array to fill RHO_D_DZDN, in the same way as
   ! done in WALL_LOOP_2 of DIVERGENCE_PART_1 (divg.f90):
   ! IAXIS faces:
   X1AXIS = IAXIS
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_IAXIS_Z(IFACE)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE ! Already done on previous loops.
      CALL GET_BBREGFACE_RHO_D_DZDN
      ! NOTE: Boundary condition diffusive mass fluxes are already made realizable:
      IBM_REGFACE_IAXIS_Z(IFACE)%RHO_D_DZDN(N) = RHO_D_DZDN ! Use single value of RHO_D_DZDN
   ENDDO

   ! JAXIS faces:
   X1AXIS = JAXIS
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_JAXIS_Z(IFACE)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      CALL GET_BBREGFACE_RHO_D_DZDN
      ! NOTE: Boundary condition diffusive mass fluxes are already made realizable:
      IBM_REGFACE_JAXIS_Z(IFACE)%RHO_D_DZDN(N) = RHO_D_DZDN ! Use single value of RHO_D_DZDN
   ENDDO

   ! KAXIS faces:
   X1AXIS = KAXIS
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = IBM_REGFACE_KAXIS_Z(IFACE)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      CALL GET_BBREGFACE_RHO_D_DZDN
      ! NOTE: Boundary condition diffusive mass fluxes are already made realizable:
      IBM_REGFACE_KAXIS_Z(IFACE)%RHO_D_DZDN(N) = RHO_D_DZDN ! Use single value of RHO_D_DZDN
   ENDDO

   ! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z
      IW = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      I      = IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
      J      = IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
      K      = IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
      X1AXIS = IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)
      CALL GET_BBRCFACE_RHO_D_DZDN
      IBM_RCFACE_Z(IFACE)%RHO_D_DZDN(N) = RHO_D_DZDN
      IBM_RCFACE_Z(IFACE)%ZZ_FACE(N)   = ZZ_FACE
      IBM_RCFACE_Z(IFACE)%TMP_FACE     = TMP_FACE
   ENDDO

   ! GASPHASE cut-faces:
   ! In case of Cut Faces and OPEN boundaries redefine the location of the guard cells with atmospheric conditions:
   DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
      IW = MESHES(NM)%CUT_FACE(ICF)%IWC
      IF( WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE

      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      ! External boundary cut-cells of type OPEN_BOUNDARY:
      GASBOUND_IF : IF(WALL(IW)%BOUNDARY_TYPE==OPEN_BOUNDARY) THEN
         ! Run over local cut-faces:
         DO IFACE=1,CUT_FACE(ICF)%NFACE
            X1F= CUT_FACE(ICF)%XYZCEN(X1AXIS,IFACE)
            IF (WALL(IW)%ONE_D%IOR > 0) THEN
               IDX= 0.5_EB/(CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE)-X1F) ! Assumes DX twice the distance from WALL_CELL to
                                                                      ! internal cut-cell centroid.
            ELSE
               IDX= 0.5_EB/(X1F-CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE))
            ENDIF
            CCM1= 0.5_EB; CCP1= 0.5_EB
            SELECT CASE (X1AXIS)
            CASE(IAXIS)
               MUV(-1:0)       =     MU(I:I+1,J,K)
               MU_DNSV(-1:0)   = MU_DNS(I:I+1,J,K)
               TMPV(-1:0)      =    TMP(I:I+1,J,K)
               RHOPV(-1:0)     =   RHOP(I:I+1,J,K)
               ZZPV(-1:0)      =    ZZP(I:I+1,J,K,N)
            CASE(JAXIS)
               MUV(-1:0)       =     MU(I,J:J+1,K)
               MU_DNSV(-1:0)   = MU_DNS(I,J:J+1,K)
               TMPV(-1:0)      =    TMP(I,J:J+1,K)
               RHOPV(-1:0)     =   RHOP(I,J:J+1,K)
               ZZPV(-1:0)      =    ZZP(I,J:J+1,K,N)
            CASE(KAXIS)
               MUV(-1:0)       =     MU(I,J,K:K+1)
               MU_DNSV(-1:0)   = MU_DNS(I,J,K:K+1)
               TMPV(-1:0)      =    TMP(I,J,K:K+1)
               RHOPV(-1:0)     =   RHOP(I,J,K:K+1)
               ZZPV(-1:0)      =    ZZP(I,J,K:K+1,N)
            END SELECT
            ! Interpolate D_Z to the face, linear interpolation:
            DO ISIDE=-1,0
               SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
               CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                  ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
                  JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
                  TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
                  RHOPV(ISIDE)=        PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
                  ZZPV(ISIDE) =        PRFCT *CUT_CELL(ICC)%ZZ(N,JCC) + &
                                (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
               END SELECT
               CALL GET_CCREGION_CELL_DIFFUSIVITY(RHOPV(ISIDE),D_Z_N,MUV(ISIDE),&
                                                MU_DNSV(ISIDE),TMPV(ISIDE),D_Z_TEMP(ISIDE))
            ENDDO

            ! One Term defined flux:
            DIFF_FACE = CCM1*RHOPV(-1)*D_Z_TEMP(-1) + CCP1*RHOPV(0)*D_Z_TEMP(0)
            CUT_FACE(ICF)%RHO_D_DZDN(N,IFACE) = DIFF_FACE*IDX*(ZZPV(0) - ZZPV(-1) ) ! rho D_a Grad(Y_a)
            CUT_FACE(ICF)%ZZ_FACE(N,IFACE) = CCM1*ZZPV(-1) + CCP1*ZZPV(0) ! Linear interpolation of ZZ to the face.
            CUT_FACE(ICF)%TMP_FACE(IFACE)  = CCM1*TMPV(-1) + CCP1*TMPV(0) ! Linear interpolation of TMP to the face.

         ENDDO ! IFACE

      ELSE

         ! Other boundary conditions:
         DO IFACE=1,CUT_FACE(ICF)%NFACE
            CALL GET_BBCUTFACE_RHO_D_DZDN
            CUT_FACE(ICF)%RHO_D_DZDN(N,IFACE) = RHO_D_DZDN
            CUT_FACE(ICF)%ZZ_FACE(N,IFACE) = ZZ_FACE
            CUT_FACE(ICF)%TMP_FACE(IFACE)  = TMP_FACE
         ENDDO

      ENDIF GASBOUND_IF

   ENDDO ! ICF

   ! Finally INBOUNDARY cut-faces, compute RHO_D_DZDN using CFACES:
   ! TO DO.

   ! Finally EXIM faces -> we use RHO_D_DZDX,Y,Z previously defined on divg.f90:
   ! No need to do anything on this initial DIFFUSIVE_FLUX_LOOP, as consistency already enforced
   ! on divg.f90.

ENDDO DIFFUSIVE_FLUX_LOOP

DEALLOCATE(ZZ_GET,RHO_D_DZDN_GET,N_ZZ_MAX_V)

RETURN

CONTAINS

SUBROUTINE GET_BBREGFACE_RHO_D_DZDN

TYPE(WALL_TYPE), POINTER :: WC=>NULL()
INTEGER :: IIG, JJG, KKG, IOR, N_ZZ_MAX
REAL(EB) :: RHO_D_DZDN_GET(1:N_TRACKED_SPECIES)
WC => WALL(IW)
IIG = WC%ONE_D%IIG
JJG = WC%ONE_D%JJG
KKG = WC%ONE_D%KKG
IOR = WC%ONE_D%IOR
N_ZZ_MAX = MAXLOC(WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES),1)
RHO_D_DZDN = 2._EB*WC%ONE_D%RHO_D_F(N)*(ZZP(IIG,JJG,KKG,N)-WC%ONE_D%ZZ_F(N))*WC%ONE_D%RDN
IF (N==N_ZZ_MAX) THEN
   RHO_D_DZDN_GET = 2._EB*WC%ONE_D%RHO_D_F(:)*(ZZP(IIG,JJG,KKG,:)-WC%ONE_D%ZZ_F(:))*WC%ONE_D%RDN
   RHO_D_DZDN = -(SUM(RHO_D_DZDN_GET(:))-RHO_D_DZDN)
ENDIF

IF (IOR < 0) RHO_D_DZDN = -RHO_D_DZDN ! This is to switch the sign of the spatial derivative in high side boundaries.

END SUBROUTINE GET_BBREGFACE_RHO_D_DZDN

SUBROUTINE GET_BBRCFACE_RHO_D_DZDN

TYPE(WALL_TYPE), POINTER :: WC=>NULL()
INTEGER :: IIG, JJG, KKG, IOR, N_ZZ_MAX
REAL(EB) :: ZZ_G, ZZ_GV(1:N_TRACKED_SPECIES),RHO_D_DZDN_GET(1:N_TRACKED_SPECIES)

WC => WALL(IW)
IIG = WC%ONE_D%IIG
JJG = WC%ONE_D%JJG
KKG = WC%ONE_D%KKG
IOR = WC%ONE_D%IOR
! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
!                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
ISIDE = -1 + (SIGN(1,IOR)+1) / 2
SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
CASE(IBM_FTYPE_RGGAS) ! Regular cell.
   ZZ_G = ZZP(IIG,JJG,KKG,N)
   ZZ_GV(1:N_TRACKED_SPECIES)= ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)
CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
   ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
   JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
   ZZ_G =               PRFCT *CUT_CELL(ICC)%ZZ(N,JCC) + &
                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
   ZZ_GV(1:N_TRACKED_SPECIES)= PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                        (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
END SELECT

SELECT CASE(X1AXIS)
    CASE(IAXIS)
       X1F= MESHES(NM)%X(I)
    CASE(JAXIS)
       X1F= MESHES(NM)%Y(J)
    CASE(KAXIS)
       X1F= MESHES(NM)%Z(K)
END SELECT

IF (IOR > 0) THEN !Cell or cutcell on high side of RC face:
   IDX = 1._EB / (IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS,HIGH_IND)-X1F)
ELSE
   IDX = 1._EB / (X1F-IBM_RCFACE_Z(IFACE)%XCEN(X1AXIS, LOW_IND))
ENDIF

N_ZZ_MAX = MAXLOC(WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES),1)
RHO_D_DZDN = WC%ONE_D%RHO_D_F(N)*(ZZ_G-WC%ONE_D%ZZ_F(N))*IDX
IF (N==N_ZZ_MAX) THEN
   RHO_D_DZDN_GET = WC%ONE_D%RHO_D_F(:)*(ZZ_GV(:)-WC%ONE_D%ZZ_F(:))*IDX
   RHO_D_DZDN = -(SUM(RHO_D_DZDN_GET(:))-RHO_D_DZDN)
ENDIF

IF (IOR < 0) RHO_D_DZDN = -RHO_D_DZDN ! This is to switch the sign of the spatial derivative in high side boundaries.
DIFF_FACE = WC%ONE_D%RHO_D_F(N)/WC%ONE_D%RHO_F
ZZ_FACE   = WC%ONE_D%ZZ_F(N)
TMP_FACE  = WC%ONE_D%TMP_F

END SUBROUTINE GET_BBRCFACE_RHO_D_DZDN


SUBROUTINE GET_BBCUTFACE_RHO_D_DZDN

TYPE(WALL_TYPE), POINTER :: WC=>NULL()
INTEGER :: IOR, N_ZZ_MAX
REAL(EB) :: ZZ_G, ZZ_GV(1:N_TRACKED_SPECIES),RHO_D_DZDN_GET(1:N_TRACKED_SPECIES)

WC => WALL(IW)
IOR = WC%ONE_D%IOR

X1F= CUT_FACE(ICF)%XYZCEN(X1AXIS,IFACE)
IF (IOR > 0) THEN
   IDX= 1._EB/(CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE)-X1F)
ELSE
   IDX= 1._EB/(X1F-CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE))
ENDIF
! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ISIDE=-1,
!                              when sign of IOR is  1 -> use High Side cell -> ISIDE= 0 .
ISIDE = -1 + (SIGN(1,IOR)+1) / 2
SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
   ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
   JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
   ZZ_G =               PRFCT *CUT_CELL(ICC)%ZZ(N,JCC) + &
                 (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
   ZZ_GV(1:N_TRACKED_SPECIES)= PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                        (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
END SELECT

N_ZZ_MAX = MAXLOC(WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES),1)
RHO_D_DZDN = WC%ONE_D%RHO_D_F(N)*(ZZ_G-WC%ONE_D%ZZ_F(N))*IDX
IF (N==N_ZZ_MAX) THEN
   RHO_D_DZDN_GET = WC%ONE_D%RHO_D_F(:)*(ZZ_GV(:)-WC%ONE_D%ZZ_F(:))*IDX
   RHO_D_DZDN = -(SUM(RHO_D_DZDN_GET(:))-RHO_D_DZDN)
ENDIF

IF (IOR < 0) RHO_D_DZDN = -RHO_D_DZDN ! This is to switch the sign of the spatial derivative in high side boundaries.
DIFF_FACE = WC%ONE_D%RHO_D_F(N)/WC%ONE_D%RHO_F
ZZ_FACE   = WC%ONE_D%ZZ_F(N)
TMP_FACE  = WC%ONE_D%TMP_F

END SUBROUTINE GET_BBCUTFACE_RHO_D_DZDN

END SUBROUTINE CCREGION_DIFFUSIVE_MASS_FLUXES


! ------------------------------ CCREGION_DENSITY -------------------------------

SUBROUTINE CCREGION_DENSITY(T,DT)

USE PHYSICAL_FUNCTIONS, ONLY : GET_SPECIFIC_GAS_CONSTANT
USE MPI_F08

REAL(EB), INTENT(IN) :: T,DT

! Local Variables:
INTEGER :: N
INTEGER :: I,J,K,NM,ICC,JCC,NCELL
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES)
REAL(EB) :: VCCELL
REAL(EB) :: DUMMYT
REAL(EB) :: TNOW
! CHARACTER(len=20) :: filename
! LOGICAL, SAVE :: FIRST_CALL = .TRUE.
!

! Dummy on T:
DUMMYT = T

IF (SOLID_PHASE_ONLY) RETURN

TNOW = CURRENT_TIME()

SELECT CASE (PERIODIC_TEST)
   CASE DEFAULT
      IF (ICYC<=1) RETURN ! In order to avoid instabilities due to unphysical initial flow fields.
   CASE (5,8)
      RETURN
   CASE (4,7,11,21,22)
      ! CONTINUE
END SELECT

! Advance scalars and density, sanitize results if needed:
CALL CCREGION_DENSITY_EXPLICIT(T,DT)

! Compute molecular weight term RSUM=R0*SUM(Y_i/W_i). Here WBAR=1/SUM(Y_i/W_i).
! Compute temperature in regular and cut-cells, from equation of state:
IF (PREDICTOR) THEN

   MESHES_LOOP1 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

      CALL POINT_TO_MESH(NM)

      ! First Regular Cells:
      ! Compute molecular weight term RSUM=R0*SUM(Y_i/W_i).
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                     ! underlying Cartesian cells and
                                                     ! solid cells.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZS(I,J,K,1:N_TRACKED_SPECIES)
               CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K))
            ENDDO
         ENDDO
      ENDDO

      ! Extract predicted temperature at next time step from Equation of State
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                     ! underlying Cartesian cells and
                                                     ! solid cells.
               TMP(I,J,K) = PBAR_S(K,PRESSURE_ZONE(I,J,K))/(RSUM(I,J,K)*RHOS(I,J,K))
            ENDDO
         ENDDO
      ENDDO

      ! Store RHO*ZZ values at step n:
      IF (.NOT.ALLOCATED(MESHES(NM)%RHO_ZZN)) &
      ALLOCATE(MESHES(NM)%RHO_ZZN(0:IBP1,0:JBP1,0:KBP1,N_TOTAL_SCALARS))

      DO N=1,N_TOTAL_SCALARS
         MESHES(NM)%RHO_ZZN(:,:,:,N) = MESHES(NM)%RHO(:,:,:)*MESHES(NM)%ZZ(:,:,:,N)
      ENDDO

      ! Second cut-cells, these variables being filled are only used for exporting to slices and applying Boundary
      ! conditions on external walls other than NULL or INTERPOLATED in WALL_BC (wall.f90):
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         NCELL = CUT_CELL(ICC)%NCELL
         I     = CUT_CELL(ICC)%IJK(IAXIS)
         J     = CUT_CELL(ICC)%IJK(JAXIS)
         K     = CUT_CELL(ICC)%IJK(KAXIS)
         VCCELL = 0._EB
         TMP(I,J,K)=0._EB
         RHOS(I,J,K)=0._EB
         ZZS(I,J,K,1:N_TRACKED_SPECIES)=0._EB
         RSUM(I,J,K)=0._EB
         DO JCC=1,NCELL
            ! Compute molecular weight term RSUM=R0*SUM(Y_i/W_i).
            ZZ_GET(1:N_TRACKED_SPECIES) = CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,CUT_CELL(ICC)%RSUM(JCC))
            ! Extract predicted temperature at next time step from Equation of State
            ! Use for pressure the height of the underlying cartesian cell centroid:
            CUT_CELL(ICC)%TMP(JCC) = &
            PBAR_S(K,PRESSURE_ZONE(I,J,K))/(CUT_CELL(ICC)%RSUM(JCC)*CUT_CELL(ICC)%RHOS(JCC))

            TMP(I,J,K) = TMP(I,J,K) + CUT_CELL(ICC)%TMP(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            RHOS(I,J,K)= RHOS(I,J,K)+ CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            ZZS(I,J,K,1:N_TRACKED_SPECIES) = ZZS(I,J,K,1:N_TRACKED_SPECIES) + &
                                             ZZ_GET(1:N_TRACKED_SPECIES)*CUT_CELL(ICC)%VOLUME(JCC)
            RSUM(I,J,K)= RSUM(I,J,K)+ CUT_CELL(ICC)%RSUM(JCC)*CUT_CELL(ICC)%VOLUME(JCC)

            VCCELL = VCCELL + CUT_CELL(ICC)%VOLUME(JCC)

         ENDDO

         ! Volume average cell variables to underlying cell:
         TMP(I,J,K) = TMP(I,J,K)/VCCELL
         RHOS(I,J,K)= RHOS(I,J,K)/VCCELL
         ZZS(I,J,K,1:N_TRACKED_SPECIES)=ZZS(I,J,K,1:N_TRACKED_SPECIES)/VCCELL
         RSUM(I,J,K)=RSUM(I,J,K)/VCCELL

      ENDDO

      ! Finally set to ambient temperature the temp of SOLID cells:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_CGSC) /= IBM_SOLID) CYCLE
               TMP(I,J,K) = TMPA
            ENDDO
         ENDDO
      ENDDO

   ENDDO MESHES_LOOP1

ELSE ! CORRECTOR

   MESHES_LOOP2 : DO NM=1,NMESHES

      IF (PROCESS(NM)/=MY_RANK) CYCLE

      CALL POINT_TO_MESH(NM)

      ! Compute molecular weight term RSUM=R0*SUM(Y_i/W_i)
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                     ! underlying Cartesian cells and
                                                     ! solid cells.
               ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
               CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM(I,J,K))
            ENDDO
         ENDDO
      ENDDO

      ! Extract predicted temperature at next time step from Equation of State
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                     ! underlying Cartesian cells and
                                                     ! solid cells.
               TMP(I,J,K) = PBAR(K,PRESSURE_ZONE(I,J,K))/(RSUM(I,J,K)*RHO(I,J,K))

            ENDDO
         ENDDO
      ENDDO

      ! Second cut-cells, these variables being filled are only used for exporting to slices and applying Boundary
      ! conditions on external walls other than NULL or INTERPOLATED in WALL_BC (wall.f90):
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         NCELL = CUT_CELL(ICC)%NCELL
         I     = CUT_CELL(ICC)%IJK(IAXIS)
         J     = CUT_CELL(ICC)%IJK(JAXIS)
         K     = CUT_CELL(ICC)%IJK(KAXIS)
         VCCELL = 0._EB
         TMP(I,J,K)=0._EB
         RHO(I,J,K)=0._EB
         ZZ(I,J,K,1:N_TRACKED_SPECIES)=0._EB
         RSUM(I,J,K)=0._EB
         DO JCC=1,NCELL
            ! Compute molecular weight term RSUM=R0*SUM(Y_i/W_i).
            ZZ_GET(1:N_TRACKED_SPECIES) = CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC)
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,CUT_CELL(ICC)%RSUM(JCC))
            ! Extract predicted temperature at next time step from Equation of State
            ! Use for pressure the height of the underlying cartesian cell centroid:
            CUT_CELL(ICC)%TMP(JCC) = &
            PBAR(K,PRESSURE_ZONE(I,J,K))/(CUT_CELL(ICC)%RSUM(JCC)*CUT_CELL(ICC)%RHO(JCC))


            TMP(I,J,K) = TMP(I,J,K) + CUT_CELL(ICC)%TMP(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            RHO(I,J,K) = RHO(I,J,K) + CUT_CELL(ICC)%RHO(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
            ZZ(I,J,K,1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES) + &
                                            ZZ_GET(1:N_TRACKED_SPECIES)*CUT_CELL(ICC)%VOLUME(JCC)
            RSUM(I,J,K)= RSUM(I,J,K)+ CUT_CELL(ICC)%RSUM(JCC)*CUT_CELL(ICC)%VOLUME(JCC)

            VCCELL = VCCELL + CUT_CELL(ICC)%VOLUME(JCC)

         ENDDO

         ! Volume average cell variables to underlying cell:
         TMP(I,J,K) = TMP(I,J,K)/VCCELL
         RHO(I,J,K) = RHO(I,J,K)/VCCELL
         ZZ(I,J,K,1:N_TRACKED_SPECIES)=ZZ(I,J,K,1:N_TRACKED_SPECIES)/VCCELL
         RSUM(I,J,K)=RSUM(I,J,K)/VCCELL

      ENDDO

      ! Finally set to ambient temperature the temp of SOLID cells:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_CGSC) /= IBM_SOLID) CYCLE
               TMP(I,J,K) = TMPA
            ENDDO
         ENDDO
      ENDDO

   ENDDO MESHES_LOOP2

ENDIF ! PREDICTOR

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(CCREGION_DENSITY_TIME_INDEX) = T_CC_USED(CCREGION_DENSITY_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE CCREGION_DENSITY

! ----------------------------- CCREGION_DENSITY_EXPLICIT ------------------------

SUBROUTINE CCREGION_DENSITY_EXPLICIT(T,DT)

REAL(EB), INTENT(IN) :: T,DT

! Local variables:
INTEGER :: N
INTEGER :: IROW_LOC
REAL(EB):: DUMMYT

! Just to avoid compilation warnings: T might be used to define a time dependent source.
DUMMYT = T

! Loop through species:
! This loop performs an either implicit or explicit time advancement of the transport equations for each
! chemical species on the cut-cell implicit region, plus explicit reaction (as done on FDS).
! Scalar bounds are checked on the implicit region regular and cut-cells:
SPECIES_LOOP: DO N=1,N_TOTAL_SCALARS

   IF( (PREDICTOR.AND.FIRST_PASS) .OR. CORRECTOR) THEN
      ! RHS vector (Adv+diff)*zz+F_BC, derived from boundary conditions on immersed and domain Boundaries:
      F_Z(:) = 0._EB
      CALL GET_EXPLICIT_ADVDIFFVECTOR_SCALAR_3D(N)

      ! Add Advective fluxes due to PRES_ON_WHOLE_DOMAIN for F_Z:
      CALL GET_ADVDIFFVECTOR_SCALAR_3D(N)

      ! Here add the reaction source term M_DOT_PPP, treated explicitly:
      IF (N_LP_ARRAY_INDICES>0 .OR. N_REACTIONS>0 .OR. ANY(SPECIES_MIXTURE%DEPOSITING)) THEN
         CALL GET_M_DOT_PPP_SCALAR_3D(N)
      ENDIF

      IF (PERIODIC_TEST==7) CALL GET_SHUNN3_QZ(T,N)
      IF (PERIODIC_TEST==21 .OR. PERIODIC_TEST==22 .OR. PERIODIC_TEST==23) CALL CCREGION_ROTATED_CUBE_RHS_ZZ(T,N)

      ! Get rho*zz vector at step n:
      CALL GET_RHOZZVECTOR_SCALAR_3D(N)
   ENDIF

   IF (PREDICTOR) THEN
      IF (FIRST_PASS) THEN
         F_Z0(:,N) = F_Z(:)
         RZ_Z0(:,N) = RZ_Z(:)
      ELSE
         F_Z(:) = F_Z0(:,N)
         RZ_Z(:)= RZ_Z0(:,N)
      ENDIF
   ENDIF

   IF (PREDICTOR) THEN

      ! Here F_Z: (Adv+Diff)*(rho z)^n + F^n
      ! Advance with Explicit Euler: RZ_Z = RZ_Z - DT*M_MAT_Z^-1*F_Z: where initially
      ! RZ_Z = (rho z)^n, filled in GET_RHOZZVECTOR_SCALAR_3D
      DO IROW_LOC=1,NUNKZ_LOCAL
         RZ_Z(IROW_LOC) = RZ_Z(IROW_LOC) - DT * F_Z(IROW_LOC) / M_MAT_Z(IROW_LOC)
      ENDDO

   ELSE ! CORRECTOR

      ! Here F_Z: (Adv+Diff)*(rho z)^* + F^*
      ! Advance with Corrector SSPRK2: RZ_Z = RZ_Z - DT/2*M_MAT_Z^-1*F_Z: where initially
      ! RZ_Z = 1/2*((rho z)^n + (rho z)^*)
      DO IROW_LOC=1,NUNKZ_LOCAL
         RZ_Z(IROW_LOC) = RZ_Z(IROW_LOC) - 0.5_EB * DT * F_Z(IROW_LOC) / M_MAT_Z(IROW_LOC)
      ENDDO

   ENDIF

   ! Copy back to RHOZZP and CUT_CELL:
   CALL PUT_RHOZZVECTOR_SCALAR_3D(N)

ENDDO SPECIES_LOOP

! Recompute RHOP, and check for positivity, define mass fraction ZZ and clip if necessary:
CALL GET_RHOZZ_CCIMPREG_3D

RETURN
END SUBROUTINE CCREGION_DENSITY_EXPLICIT


! ---------------------------- GET_M_DOT_PPP_SCALAR_3D ---------------------------

SUBROUTINE GET_M_DOT_PPP_SCALAR_3D(N)

INTEGER, INTENT(IN) :: N

! Local Variables:
INTEGER :: NM,I,J,K,IROW,ICC,JCC,NCELL

! Mesh Loop:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! First add M_DOT_PPP on regular cells to source F_Z:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                  ! underlying Cartesian cells and
                                                  ! solid cells.
            IROW = CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
            F_Z(IROW) = F_Z(IROW) - M_DOT_PPP(I,J,K,N)*DX(I)*DY(J)*DZ(K)
         ENDDO
      ENDDO
   ENDDO

   ! Then add Cut-cell contributions to F_Z:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
      NCELL=CUT_CELL(ICC)%NCELL
      DO JCC=1,NCELL
         IROW = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
         F_Z(IROW) = F_Z(IROW) - CUT_CELL(ICC)%M_DOT_PPP(N,JCC)*CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO
   ENDDO

   ! Finally if Corrector zero out M_DOT_PPP and D_SOURCE:
   IF (CORRECTOR) THEN
      M_DOT_PPP(:,:,:,N) = 0._EB
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         NCELL=CUT_CELL(ICC)%NCELL
         CUT_CELL(ICC)%M_DOT_PPP(N,1:NCELL) = 0._EB
      ENDDO
      IF (N == N_TOTAL_SCALARS) THEN
         D_SOURCE(:,:,:)  = 0._EB
         DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
            NCELL=CUT_CELL(ICC)%NCELL
            CUT_CELL(ICC)%D_SOURCE(1:NCELL) = 0._EB
         ENDDO
      ENDIF
   ENDIF

ENDDO MESH_LOOP

RETURN
END SUBROUTINE GET_M_DOT_PPP_SCALAR_3D

! ---------------------- GET_EXPLICIT_ADVDIFFVECTOR_SCALAR_3D --------------------

SUBROUTINE GET_EXPLICIT_ADVDIFFVECTOR_SCALAR_3D(N)

INTEGER, INTENT(IN) :: N

! Local Variables:
INTEGER :: NM,I,J,K
REAL(EB):: PRFCT
INTEGER :: X1AXIS,IFACE,IND(LOW_IND:HIGH_IND),IND_LOC(LOW_IND:HIGH_IND),ICF
INTEGER :: LOCROW_1,LOCROW_2,ILOC,IROW,ICC,JCC,ISIDE,IW
REAL(EB):: AF,KFACE(2,2),F_LOC(2),CIJP,CIJM,VELC,ALPHAP1,AM_P1,AP_P1,RHO_Z_PV(-2:1),RHOPV(-2:1),FCT,ZZ_GET_N,FN_ZZ
REAL(EB), POINTER, DIMENSION(:,:,:)  :: RHOP=>NULL(),UP=>NULL(),VP=>NULL(),WP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:)  :: UU=>NULL(),VV=>NULL(),WW=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:):: ZZP=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()
LOGICAL :: DO_LO,DO_HI
INTEGER :: IIG,JJG,KKG,IOR
REAL(EB) :: UN

! Mesh Loop:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   UU=>WORK1
   VV=>WORK2
   WW=>WORK3

   IF (PREDICTOR) THEN
      ZZP  => ZZ
      RHOP => RHO
      UU   = U
      VV   = V
      WW   = W
      PRFCT= 1._EB
      WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
         WC=>WALL(IW)
         IF (WC%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY) CYCLE WALL_LOOP
         IIG = WC%ONE_D%IIG
         JJG = WC%ONE_D%JJG
         KKG = WC%ONE_D%KKG
         IOR = WC%ONE_D%IOR
         SELECT CASE(WC%BOUNDARY_TYPE)
            CASE DEFAULT; CYCLE WALL_LOOP
            ! SOLID_BOUNDARY is not currently functional here, but keep for testing
            CASE(SOLID_BOUNDARY);        UN = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL
            CASE(INTERPOLATED_BOUNDARY); UN = UVW_SAVE(IW)
         END SELECT
         SELECT CASE(IOR)
            CASE( 1); UU(IIG-1,JJG,KKG) = UN
            CASE(-1); UU(IIG,JJG,KKG)   = UN
            CASE( 2); VV(IIG,JJG-1,KKG) = UN
            CASE(-2); VV(IIG,JJG,KKG)   = UN
            CASE( 3); WW(IIG,JJG,KKG-1) = UN
            CASE(-3); WW(IIG,JJG,KKG)   = UN
         END SELECT
      ENDDO WALL_LOOP

   ELSE
      ZZP  => ZZS
      RHOP => RHOS
      UU   = US
      VV   = VS
      WW   = WS
      PRFCT= 0._EB
      WALL_LOOP_2: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
         WC=>WALL(IW)
         IF (WC%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY) CYCLE WALL_LOOP_2
         IIG = WC%ONE_D%IIG
         JJG = WC%ONE_D%JJG
         KKG = WC%ONE_D%KKG
         IOR = WC%ONE_D%IOR
         SELECT CASE(WC%BOUNDARY_TYPE)
            CASE DEFAULT; CYCLE WALL_LOOP_2
            ! SOLID_BOUNDARY is not currently functional here, but keep for testing
            CASE(SOLID_BOUNDARY);        UN = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL_S
            CASE(INTERPOLATED_BOUNDARY); UN = UVW_SAVE(IW)
         END SELECT
         SELECT CASE(IOR)
            CASE( 1); UU(IIG-1,JJG,KKG) = UN
            CASE(-1); UU(IIG,JJG,KKG)   = UN
            CASE( 2); VV(IIG,JJG-1,KKG) = UN
            CASE(-2); VV(IIG,JJG,KKG)   = UN
            CASE( 3); WW(IIG,JJG,KKG-1) = UN
            CASE(-3); WW(IIG,JJG,KKG)   = UN
         END SELECT
      ENDDO WALL_LOOP_2
   ENDIF

   ! The use of UU, VV, WW is to maintain the divergence consistent in cells next to INTERPOLATED_BOUNDARY faces, when
   ! The solver being used is the default POISSON solver (i.e. use normal velocities with velocity error).
   UP => UU
   VP => VV
   WP => WW

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.

   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.

   ! First add advective fluxes to internal and INTERPOLATED_BOUNDARY regular and cut-cells in the CC region:
   ! IAXIS faces:
   X1AXIS = IAXIS
   REGFACE_Z => IBM_REGFACE_IAXIS_Z
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
      I     = REGFACE_Z(IFACE)%IJK(IAXIS)
      J     = REGFACE_Z(IFACE)%IJK(JAXIS)
      K     = REGFACE_Z(IFACE)%IJK(KAXIS)
      DO_LO = REGFACE_Z(IFACE)%DO_LO_IND
      DO_HI = REGFACE_Z(IFACE)%DO_HI_IND
      ! Unknowns on related cells:
      IND_LOC(LOW_IND) = CCVAR(I  ,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= CCVAR(I+1,J,K,IBM_UNKZ) - UNKZ_IND(NM_START)

      AF = DY(J)*DZ(K)
      IF (DO_LO) F_Z(IND_LOC( LOW_IND)) = F_Z(IND_LOC( LOW_IND)) + REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
      IF (DO_HI) F_Z(IND_LOC(HIGH_IND)) = F_Z(IND_LOC(HIGH_IND)) - REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
   ENDDO

   ! JAXIS faces:
   X1AXIS = JAXIS
   REGFACE_Z => IBM_REGFACE_JAXIS_Z
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
      I     = REGFACE_Z(IFACE)%IJK(IAXIS)
      J     = REGFACE_Z(IFACE)%IJK(JAXIS)
      K     = REGFACE_Z(IFACE)%IJK(KAXIS)
      DO_LO = REGFACE_Z(IFACE)%DO_LO_IND
      DO_HI = REGFACE_Z(IFACE)%DO_HI_IND
      ! Unknowns on related cells:
      IND_LOC(LOW_IND) = CCVAR(I,J  ,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= CCVAR(I,J+1,K,IBM_UNKZ) - UNKZ_IND(NM_START)

      AF = DX(I)*DZ(K)
      IF (DO_LO) F_Z(IND_LOC( LOW_IND)) = F_Z(IND_LOC( LOW_IND)) + REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
      IF (DO_HI) F_Z(IND_LOC(HIGH_IND)) = F_Z(IND_LOC(HIGH_IND)) - REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
   ENDDO

   ! KAXIS faces:
   X1AXIS = KAXIS
   REGFACE_Z => IBM_REGFACE_KAXIS_Z
   DO IFACE=1,MESHES(NM)%IBM_NREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE
      I     = REGFACE_Z(IFACE)%IJK(IAXIS)
      J     = REGFACE_Z(IFACE)%IJK(JAXIS)
      K     = REGFACE_Z(IFACE)%IJK(KAXIS)
      DO_LO = REGFACE_Z(IFACE)%DO_LO_IND
      DO_HI = REGFACE_Z(IFACE)%DO_HI_IND
      ! Unknowns on related cells:
      IND_LOC(LOW_IND) = CCVAR(I,J,K  ,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= CCVAR(I,J,K+1,IBM_UNKZ) - UNKZ_IND(NM_START)

      AF = DX(I)*DY(J)
      IF (DO_LO) F_Z(IND_LOC( LOW_IND)) = F_Z(IND_LOC( LOW_IND)) + REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
      IF (DO_HI) F_Z(IND_LOC(HIGH_IND)) = F_Z(IND_LOC(HIGH_IND)) - REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
   ENDDO


   IF (NEW_SCALAR_TRANSPORT) THEN

   ! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z

      IW = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IWC; IF(IW > 0) CYCLE

      I      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
      J      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
      K      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(LOW_IND)
      IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(HIGH_IND)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKZ_IND(NM_START)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            AF = DY(J)*DZ(K)
            RHOPV(-2:1)      = RHOP(I-1:I+2,J,K)
            ! First two cells surrounding face:
            DO ISIDE=-1,0
               SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
               CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
                  ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
               CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                  ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
                  JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
                  RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
                  ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
               END SELECT
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDDO
            ! Lower cell:
            ISIDE=-2
            IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDIF
            ! Upper cell:
            ISIDE=1
            IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDIF
            ! Now Godunov flux limited value of rho*zz on face:
            VELC = UU(I,J,K)
            ! bar{rho*zz}:
            FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)
         CASE(JAXIS)
            AF = DX(I)*DZ(K)
            RHOPV(-2:1)      = RHOP(I,J-1:J+2,K)
            DO ISIDE=-1,0
               SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
               CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
                  ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
               CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                  ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
                  JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
                  RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
                  ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
               END SELECT
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDDO
            ! Lower cell:
            ISIDE=-2
            IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDIF
            ! Upper cell:
            ISIDE=1
            IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDIF
            ! Now Godunov flux limited value of rho*zz on face:
            VELC = VV(I,J,K)
            ! bar{rho*zz}:
            FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)
         CASE(KAXIS)
            AF = DX(I)*DY(J)
            RHOPV(-2:1)      = RHOP(I,J,K-1:K+2)
            DO ISIDE=-1,0
               SELECT CASE(IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE+2))
               CASE(IBM_FTYPE_RGGAS) ! Regular cell -> use stored TMPV from TMP array.
                  ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
               CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                  ICC = IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE+2)
                  JCC = IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE+2)
                  RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT)* CUT_CELL(ICC)%RHOS(JCC)
                  ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
               END SELECT
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDDO
            ! Lower cell:
            ISIDE=-2
            IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDIF
            ! Upper cell:
            ISIDE=1
            IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
               RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
            ENDIF
            ! Now Godunov flux limited value of rho*zz on face:
            VELC = WW(I,J,K)
            ! bar{rho*zz}:
            FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)
      END SELECT

      DO ILOC=LOCROW_1,LOCROW_2
         IROW=IND_LOC(ILOC)   ! Process Local Unknown number.
         FCT = REAL(3-2*ILOC,EB)
         F_Z(IROW) = F_Z(IROW) + FCT*FN_ZZ*VELC*AF
      ENDDO

   ENDDO

   ! Now Gasphase CUT_FACES:
   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

      IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE

      IW = MESHES(NM)%CUT_FACE(ICF)%IWC; IF(IW > 0) CYCLE

      I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
      J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
      K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      DO IFACE=1,MESHES(NM)%CUT_FACE(ICF)%NFACE

         ! Unknowns on related cells:
         IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKZ(LOW_IND,IFACE)
         IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKZ(HIGH_IND,IFACE)

         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
         IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKZ_IND(NM_START)

         AF = MESHES(NM)%CUT_FACE(ICF)%AREA(IFACE)

         ! Matrix coefficients for advection:
         VELC =        PRFCT *MESHES(NM)%CUT_FACE(ICF)%VEL(IFACE) + &
                (1._EB-PRFCT)*MESHES(NM)%CUT_FACE(ICF)%VELS(IFACE)

         RHOPV(-1:0)    = -1._EB
         RHO_Z_PV(-1:0) =  0._EB
         DO ISIDE=-1,0
            SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
               JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
               RHOPV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + (1._EB-PRFCT) *CUT_CELL(ICC)%RHOS(JCC)
               ZZ_GET_N     = PRFCT*CUT_CELL(ICC)%ZZ(N,JCC) + (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
            RHO_Z_PV(ISIDE) = RHOPV(ISIDE)*ZZ_GET_N
         ENDDO
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            ! Lower cell:
            ISIDE=-2
            IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
               RHO_Z_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*ZZ_GET_N
            ENDIF
            ! Upper cell:
            ISIDE=1
            IF (SOLID(CELL_INDEX(I+1+ISIDE,J,K)) .OR. CCVAR(I+1+ISIDE,J,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I+1+ISIDE,J,K,N)
               RHO_Z_PV(ISIDE) = RHOP(I+1+ISIDE,J,K)*ZZ_GET_N
            ENDIF
         CASE(JAXIS)
            ! Lower cell:
            ISIDE=-2
            IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
               RHO_Z_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*ZZ_GET_N
            ENDIF
            ! Upper cell:
            ISIDE=1
            IF (SOLID(CELL_INDEX(I,J+1+ISIDE,K)) .OR. CCVAR(I,J+1+ISIDE,K,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J+1+ISIDE,K,N)
               RHO_Z_PV(ISIDE) = RHOP(I,J+1+ISIDE,K)*ZZ_GET_N
            ENDIF
         CASE(KAXIS)
            ! Lower cell:
            ISIDE=-2
            IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE+1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
               RHO_Z_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*ZZ_GET_N
            ENDIF
            ! Upper cell:
            ISIDE=1
            IF (SOLID(CELL_INDEX(I,J,K+1+ISIDE)) .OR. CCVAR(I,J,K+1+ISIDE,IBM_CGSC)==IBM_SOLID) THEN
               RHO_Z_PV(ISIDE) = RHO_Z_PV(ISIDE-1) ! Use center cell.
            ELSE
               ZZ_GET_N = ZZP(I,J,K+1+ISIDE,N)
               RHO_Z_PV(ISIDE) = RHOP(I,J,K+1+ISIDE)*ZZ_GET_N
            ENDIF
         END SELECT
         VELC  = PRFCT *CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCT)*CUT_FACE(ICF)%VELS(IFACE)
         ! bar{rho*zz}:
         FN_ZZ = SCALAR_FACE_VALUE(VELC,RHO_Z_PV(-2:1),I_FLUX_LIMITER)

         DO ILOC=LOCROW_1,LOCROW_2
            IROW=IND_LOC(ILOC)     ! Process Local Unknown number.
            FCT = REAL(3-2*ILOC,EB)
            F_Z(IROW) = F_Z(IROW) + FCT*FN_ZZ*VELC*AF
         ENDDO

      ENDDO

   ENDDO

   ELSE ! NEW_SCALAR_TRANSPORT

   ! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   DO IFACE=1,MESHES(NM)%IBM_NRCFACE_Z

      IW = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

      I      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
      J      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
      K      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(LOW_IND)
      IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(HIGH_IND)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKZ_IND(NM_START)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            AF = DY(J)*DZ(K)
            IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
            ! Advective Part: Velocity u
            VELC = UP(I,J,K)
            F_LOC(1) = RHOP(I  ,J,K)*ZZP(I  ,J,K,N)
            F_LOC(2) = RHOP(I+1,J,K)*ZZP(I+1,J,K,N)
         CASE(JAXIS)
            AF = DX(I)*DZ(K)
            IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
            ! Advective Part: Velocity v
            VELC = VP(I,J,K)
            F_LOC(1) = RHOP(I,J  ,K)*ZZP(I,J  ,K,N)
            F_LOC(2) = RHOP(I,J+1,K)*ZZP(I,J+1,K,N)
         CASE(KAXIS)
            AF = DX(I)*DY(J)
            IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
            ! Advective Part: Velocity w
            VELC = WP(I,J,K)
            F_LOC(1) = RHOP(I,J,K  )*ZZP(I,J,K  ,N)
            F_LOC(2) = RHOP(I,J,K+1)*ZZP(I,J,K+1,N)
      ENDSELECT

      ! Matrix coefficients for advection:
      ALPHAP1 = SIGN( 1._EB, VELC)
      AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
      AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
      CIJM = AM_P1*VELC*AF
      CIJP = AP_P1*VELC*AF

      ! Now add to A corresponding advection and diffusion coeffs:
      !    Cols 1,2: ind(LOW_IND) ind(HIGH_IND), Rows 1,2: ind_loc(LOW_IND) ind_loc(HIGH_IND)
      KFACE(1,1) = CIJM; KFACE(2,1) =-CIJM; KFACE(1,2) = CIJP; KFACE(2,2) =-CIJP

      DO ISIDE=1,2
         IF ( MESHES(NM)%IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE) == IBM_FTYPE_CFGAS ) THEN
            ICC = MESHES(NM)%IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE)
            JCC = MESHES(NM)%IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE)
            F_LOC(ISIDE) =       PRFCT *CUT_CELL(ICC)% RHO(JCC)*CUT_CELL(ICC)% ZZ(N,JCC) + &
                          (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC)
         ENDIF
      ENDDO

      DO ILOC=LOCROW_1,LOCROW_2 ! Local row number in Kface
         IROW=IND_LOC(ILOC)   ! Process Local Unknown number.
         F_Z(IROW) = F_Z(IROW) + KFACE(ILOC,1)*F_LOC(1) + KFACE(ILOC,2)*F_LOC(2)
      ENDDO

   ENDDO

   ! Now Gasphase CUT_FACES:
   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

      IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE

      IW = MESHES(NM)%CUT_FACE(ICF)%IWC
      IF((IW > 0) .AND. .NOT.(WALL(IW)%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                              WALL(IW)%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) CYCLE

      I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
      J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
      K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
         CASE(JAXIS)
            IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
         CASE(KAXIS)
            IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
      ENDSELECT

      DO IFACE=1,MESHES(NM)%CUT_FACE(ICF)%NFACE

         ! Unknowns on related cells:
         IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKZ(LOW_IND,IFACE)
         IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKZ(HIGH_IND,IFACE)

         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
         IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKZ_IND(NM_START)

         AF = MESHES(NM)%CUT_FACE(ICF)%AREA(IFACE)

         ! Matrix coefficients for advection:
         VELC =        PRFCT *MESHES(NM)%CUT_FACE(ICF)%VEL(IFACE) + &
                (1._EB-PRFCT)*MESHES(NM)%CUT_FACE(ICF)%VELS(IFACE)

         ALPHAP1 = SIGN( 1._EB, VELC)
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1*(1._EB-BRP1))
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1*(1._EB-BRP1))
         CIJM = AM_P1*VELC*AF
         CIJP = AP_P1*VELC*AF

         ! Now add to A corresponding advection and diffusion coeffs:
         !    Cols 1,2: ind(LOW_IND) ind(HIGH_IND), Rows 1,2: ind_loc(LOW_IND) ind_loc(HIGH_IND)
         KFACE(1,1) = CIJM; KFACE(2,1) =-CIJM; KFACE(1,2) = CIJP; KFACE(2,2) =-CIJP

         F_LOC(:) = 0._EB
         DO ISIDE=1,2
            SELECT CASE(MESHES(NM)%CUT_FACE(ICF)%CELL_LIST(1,ISIDE,IFACE))
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ICC = MESHES(NM)%CUT_FACE(ICF)%CELL_LIST(2,ISIDE,IFACE)
               JCC = MESHES(NM)%CUT_FACE(ICF)%CELL_LIST(3,ISIDE,IFACE)
               F_LOC(ISIDE) =       PRFCT *CUT_CELL(ICC)% RHO(JCC)*CUT_CELL(ICC)% ZZ(N,JCC) + &
                             (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC)
            CASE DEFAULT
               WRITE(0,*) 'GET_EXPLICIT_ADVDIFFVECTOR_SCALAR_3D: ', &
               'MESHES(NM)%CUT_FACE face not connected to CC cell',NM,IFACE
            END SELECT
        ENDDO

        DO ILOC=LOCROW_1,LOCROW_2 ! Local row number in Kface
           IROW=IND_LOC(ILOC)     ! Process Local Unknown number.
           F_Z(IROW) = F_Z(IROW) + KFACE(ILOC,1)*F_LOC(1) + KFACE(ILOC,2)*F_LOC(2)
        ENDDO

      ENDDO

   ENDDO

   ENDIF ! NEW_SCALAR_TRANSPORT


   ! Case of PRES_ON_WHOLE_DOMAIN, we have non-zero velocities on INBOUNDARY cut-faces:
   ! Done on CALL GET_ADVDIFFVECTOR_SCALAR_3D(N)

   ! Then add (Del rho D Del Z)*dv computed on CCDIVERGENCE_PART_1:
   ! Loop over regular cells on CC region:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                  ! underlying Cartesian cells and
                                                  ! solid cells.
            IROW  = CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
            F_Z(IROW) = F_Z(IROW) - DEL_RHO_D_DEL_Z(I,J,K,N)*(DX(I)*DY(J)*DZ(K))
         ENDDO
      ENDDO
   ENDDO

   ! Now cut-cells:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      I = CUT_CELL(ICC)%IJK(IAXIS)
      J = CUT_CELL(ICC)%IJK(JAXIS)
      K = CUT_CELL(ICC)%IJK(KAXIS)
      ! Don't count cut-cells inside an OBST:
      IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
      DO JCC=1,CUT_CELL(ICC)%NCELL
         IROW = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
         F_Z(IROW) = F_Z(IROW) - CUT_CELL(ICC)%DEL_RHO_D_DEL_Z_VOL(N,JCC)
      ENDDO
   ENDDO

ENDDO MESH_LOOP

RETURN
END SUBROUTINE GET_EXPLICIT_ADVDIFFVECTOR_SCALAR_3D


! ------------------------------ GET_RHOZZ_CCIMPREG_3D ---------------------------

SUBROUTINE GET_RHOZZ_CCIMPREG_3D

! Local Variables:
INTEGER :: NM,N,I,J,K,ICC,JCC,NCELL
REAL(EB), POINTER, DIMENSION(:,:,:)   :: RHOP=>NULL(),UP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
REAL(EB) :: VOLTOT
INTEGER :: NMX

! Loop meshes:
MESH_LOOP : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN
      RHOP => RHOS
      ZZP  => ZZS
      UP   => U

      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         NCELL=CUT_CELL(ICC)%NCELL
         DO JCC=1,NCELL
            ! Get rho = sum(rho*z_alpha)
            CUT_CELL(ICC)%RHOS(JCC) = SUM(CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC))

            IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
               ! Check mass density for positivity
               IF ( (CUT_CELL(ICC)%RHOS(JCC)<RHOMIN) .OR. (CUT_CELL(ICC)%RHOS(JCC)>RHOMAX) ) THEN
                  WRITE(LU_ERR,*) 'GET_RHOZZ_CCIMPREG_3D CC Pred:',ICC,JCC,CUT_CELL(ICC)%VOLUME(JCC)
                  WRITE(LU_ERR,*) 'CELL Location=',X(CUT_CELL(ICC)%IJK(IAXIS)),Y(CUT_CELL(ICC)%IJK(JAXIS)),&
                                                   Z(CUT_CELL(ICC)%IJK(KAXIS))
                  WRITE(LU_ERR,*) 'RHOP,MIN,MAX=',CUT_CELL(ICC)%RHOS(JCC),RHOMIN,RHOMAX
               ENDIF
            ENDIF

            ! Extract z from rho*z
            CUT_CELL(ICC)%ZZS(1:N_TOTAL_SCALARS,JCC) = CUT_CELL(ICC)%ZZS(1:N_TOTAL_SCALARS,JCC)/CUT_CELL(ICC)%RHOS(JCC)

            IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
               ! Check bounds on z:
               DO N=1,N_TOTAL_SCALARS
                  IF ( (CUT_CELL(ICC)%ZZS(N,JCC)<(0._EB-GEOMEPS)) .OR. (CUT_CELL(ICC)%ZZS(N,JCC)>(1._EB+GEOMEPS)) ) THEN
                     WRITE(LU_ERR,*) 'GET_RHOZZ_CCIMPREG_3D CC Pred:',ICC,JCC,N
                     WRITE(LU_ERR,*) 'ZZP=',CUT_CELL(ICC)%ZZS(N,JCC)
                  ENDIF
               ENDDO
            ELSE
               ! Some z_alpha might be slightly below zero (bounds overrun), assign -ve mass to most abundant species:
               ! Note rho = sum(rho*z_alpha), sum(z_alpha)=1 remain unchanged.
               NMX=MAXLOC(CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC),DIM=1)
               DO N=1,N_TRACKED_SPECIES
                  IF(N==NMX) CYCLE
                  IF ( CUT_CELL(ICC)%ZZS(N,JCC) < (0._EB-TWO_EPSILON_EB)) THEN
                     CUT_CELL(ICC)%ZZS(NMX,JCC) = CUT_CELL(ICC)%ZZS(NMX,JCC) + CUT_CELL(ICC)%ZZS(N,JCC)
                     CUT_CELL(ICC)%ZZS(N,JCC)   = 0._EB
                  ENDIF
               ENDDO
            ENDIF

            ! Clip passive scalars:
            IF (N_PASSIVE_SCALARS==0) CYCLE
            CUT_CELL(ICC)%ZZS(ZETA_INDEX,JCC) = MAX(0._EB,MIN(1._EB,CUT_CELL(ICC)%ZZS(ZETA_INDEX,JCC)))
         ENDDO

         ! Dump volume average scalar mass fraction and density to Cartesian container:
         I = CUT_CELL(ICC)%IJK(IAXIS)
         J = CUT_CELL(ICC)%IJK(JAXIS)
         K = CUT_CELL(ICC)%IJK(KAXIS)
         VOLTOT = SUM( CUT_CELL(ICC)%VOLUME(1:NCELL) )
         RHOP(I,J,K) = SUM( CUT_CELL(ICC)%RHOS(1:NCELL)*CUT_CELL(ICC)%VOLUME(1:NCELL) )/VOLTOT
         DO N=1,N_TOTAL_SCALARS
            ZZP(I,J,K,N) = SUM( CUT_CELL(ICC)%ZZS(N,1:NCELL)*CUT_CELL(ICC)%VOLUME(1:NCELL) )/VOLTOT
         ENDDO

      ENDDO

   ELSE
      RHOP => RHO
      ZZP  => ZZ
      UP   => US

      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         NCELL=CUT_CELL(ICC)%NCELL
         DO JCC=1,NCELL
            ! Get rho = sum(rho*z_alpha)
            CUT_CELL(ICC)%RHO(JCC) = SUM(CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC))

            IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
               ! Check mass density for positivity
               IF ( (CUT_CELL(ICC)%RHO(JCC)<RHOMIN) .OR. (CUT_CELL(ICC)%RHO(JCC)>RHOMAX) ) THEN
                  WRITE(LU_ERR,*) 'GET_RHOZZ_CCIMPREG_3D CC Corr:',ICC,JCC,CUT_CELL(ICC)%VOLUME(JCC)
                  WRITE(LU_ERR,*) 'RHOP,MIN,MAX=',CUT_CELL(ICC)%RHO(JCC),RHOMIN,RHOMAX
               ENDIF
            ENDIF

            ! Extract z from rho*z
            CUT_CELL(ICC)%ZZ(1:N_TOTAL_SCALARS,JCC) = CUT_CELL(ICC)%ZZ(1:N_TOTAL_SCALARS,JCC)/CUT_CELL(ICC)%RHO(JCC)

            IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
               ! Check bounds on z:
               DO N=1,N_TOTAL_SCALARS
                  IF ( (CUT_CELL(ICC)%ZZ(N,JCC)<(0._EB-GEOMEPS)) .OR. (CUT_CELL(ICC)%ZZ(N,JCC)>(1._EB+GEOMEPS)) ) THEN
                     WRITE(LU_ERR,*) 'GET_RHOZZ_CCIMPREG_3D CC Corr:',ICC,JCC,N
                     WRITE(LU_ERR,*) 'ZZP=',CUT_CELL(ICC)%ZZ(N,JCC)
                  ENDIF
               ENDDO
            ELSE
               ! Some z_alpha might be slightly below zero (bounds overrun), assign -ve mass to most abundant species:
               ! Note rho = sum(rho*z_alpha), sum(z_alpha)=1 remain unchanged.
               NMX=MAXLOC(CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC),DIM=1)
               DO N=1,N_TRACKED_SPECIES
                  IF(N==NMX) CYCLE
                  IF ( CUT_CELL(ICC)%ZZ(N,JCC) < (0._EB-TWO_EPSILON_EB)) THEN
                     CUT_CELL(ICC)%ZZ(NMX,JCC) = CUT_CELL(ICC)%ZZ(NMX,JCC) + CUT_CELL(ICC)%ZZ(N,JCC)
                     CUT_CELL(ICC)%ZZ(N,JCC)   = 0._EB
                  ENDIF
               ENDDO
            ENDIF
            ! Clip passive scalars:
            IF (N_PASSIVE_SCALARS==0) CYCLE
            CUT_CELL(ICC)%ZZ(ZETA_INDEX,JCC) = MAX(0._EB,MIN(1._EB,CUT_CELL(ICC)%ZZ(ZETA_INDEX,JCC)))
         ENDDO

         ! Dump volume average scalar mass fraction and density to Cartesian container:
         I = CUT_CELL(ICC)%IJK(IAXIS)
         J = CUT_CELL(ICC)%IJK(JAXIS)
         K = CUT_CELL(ICC)%IJK(KAXIS)
         VOLTOT = SUM( CUT_CELL(ICC)%VOLUME(1:NCELL) )
         RHOP(I,J,K) = SUM( CUT_CELL(ICC)%RHO(1:NCELL)*CUT_CELL(ICC)%VOLUME(1:NCELL) )/VOLTOT
         DO N=1,N_TOTAL_SCALARS
            ZZP(I,J,K,N) = SUM( CUT_CELL(ICC)%ZZ(N,1:NCELL)*CUT_CELL(ICC)%VOLUME(1:NCELL) )/VOLTOT
         ENDDO

      ENDDO

   ENDIF

   ! Regular Cartesian cells:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (MESHES(NM)%CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not in cc-region, cut-cells
                                                             ! underlying Cartesian cells and
                                                             ! solid cells.

            ! Get rho = sum(rho*z_alpha)
            RHOP(I,J,K) = SUM(ZZP(I,J,K,1:N_TRACKED_SPECIES))

            ! Check mass density for positivity
            IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
               IF ((RHOP(I,J,K)<RHOMIN) .OR. (RHOP(I,J,K)>RHOMAX) ) THEN
                  WRITE(LU_ERR,*) 'GET_RHOZZ_CCIMPREG_3D Cart:',I,J,K
                  WRITE(LU_ERR,*) 'RHOP,MIN,MAX=',RHOP(I,J,K),RHOMIN,RHOMAX
               ENDIF
            ENDIF

            ! Extract z from rho*z
            ZZP(I,J,K,1:N_TOTAL_SCALARS) = ZZP(I,J,K,1:N_TOTAL_SCALARS)/RHOP(I,J,K)

            IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
               ! Check bounds on z:
               DO N=1,N_TOTAL_SCALARS
                  IF (ZZP(I,J,K,N)<(0._EB-GEOMEPS) .OR. ZZP(I,J,K,N)>(1._EB+GEOMEPS)) THEN
                     WRITE(LU_ERR,*) 'GET_RHOZZ_CCIMPREG_3D Cart:',I,J,K,N
                     WRITE(LU_ERR,*) 'ZZP=',ZZP(I,J,K,N)
                  ENDIF
               ENDDO
            ELSE
               ! Some z_alpha might be slightly below zero (bounds overrun), assign -ve mass to most abundant species:
               ! Note rho = sum(rho*z_alpha), sum(z_alpha)=1 remain unchanged.
               NMX=MAXLOC(ZZP(I,J,K,1:N_TRACKED_SPECIES),DIM=1)
               DO N=1,N_TRACKED_SPECIES
                  IF(N==NMX) CYCLE
                  IF ( ZZP(I,J,K,N) < (0._EB-TWO_EPSILON_EB)) THEN
                     ZZP(I,J,K,NMX) = ZZP(I,J,K,NMX) + ZZP(I,J,K,N)
                     ZZP(I,J,K,N)   = 0._EB
                  ENDIF
               ENDDO
            ENDIF
            ! Clip passive scalars:
            IF (N_PASSIVE_SCALARS==0) CYCLE
            ZZP(I,J,K,ZETA_INDEX) = MAX(0._EB,MIN(1._EB,ZZP(I,J,K,ZETA_INDEX)))

         ENDDO
      ENDDO
   ENDDO

ENDDO MESH_LOOP

RETURN
END SUBROUTINE GET_RHOZZ_CCIMPREG_3D


! --------------------------- PUT_RHOZZVECTOR_SCALAR_3D --------------------------

SUBROUTINE PUT_RHOZZVECTOR_SCALAR_3D(N)

INTEGER, INTENT(IN) :: N

! Local Variables:
INTEGER :: NM,I,J,K,IROW_LOC,ICC,JCC
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()

! Loop meshes:
MESH_LOOP : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN
      ZZP  => ZZS ! Copy rho*z obtained for species N in the end of substep container for z.
      ! Loop Cut-cells for PREDICTOR:
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         DO JCC=1,CUT_CELL(ICC)%NCELL
            IROW_LOC = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            CUT_CELL(ICC)%ZZS(N,JCC) = RZ_Z(IROW_LOC)
         ENDDO
      ENDDO

   ELSE
      ZZP  => ZZ  ! Copy rho*z obtained for species N in the end of substep container for z.
      ! Loop Cut-cells for CORRECTOR:
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         DO JCC=1,CUT_CELL(ICC)%NCELL
            IROW_LOC = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            CUT_CELL(ICC)%ZZ(N,JCC) = RZ_Z(IROW_LOC)
         ENDDO
      ENDDO

   ENDIF

   ! Loop on Cartesian Cells:
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR

            IF (MESHES(NM)%CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                             ! underlying Cartesian cells and
                                                             ! solid cells.

            ! Cut-cells are surrounded by a layer of GASPHASE cells which is
            ! also integrated implicitly.
            IROW_LOC = MESHES(NM)%CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START)

            ZZP(I,J,K,N)   = RZ_Z(IROW_LOC)
         ENDDO
      ENDDO
   ENDDO

ENDDO MESH_LOOP


RETURN
END SUBROUTINE PUT_RHOZZVECTOR_SCALAR_3D


! --------------------------- GET_RHOZZVECTOR_SCALAR_3D --------------------------

SUBROUTINE GET_RHOZZVECTOR_SCALAR_3D(N)

INTEGER, INTENT(IN) :: N

! Local Variables:
INTEGER :: NM,I,J,K,IROW_LOC,ICC,JCC

! Initialize rho*z:
RZ_Z(:) = 0._EB
RZ_ZS(:) = 0._EB

! Loop meshes:
MESH_LOOP : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN

      ! Loop on Cartesian Cells:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (MESHES(NM)%CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                                ! underlying Cartesian cells and
                                                                ! solid cells.

               ! Cut-cells are surrounded by a layer of GASPHASE cells which is
               ! also integrated implicitly.
               IROW_LOC = MESHES(NM)%CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START)
               RZ_Z(IROW_LOC) = RHO(I,J,K)*ZZ(I,J,K,N) ! Known rho*zz^n
            ENDDO
         ENDDO
      ENDDO

      ! Now loop Cut-cells:
      CUTCELL_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         DO JCC=1,CUT_CELL(ICC)%NCELL
            IROW_LOC = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            RZ_Z(IROW_LOC) = CUT_CELL(ICC)%RHO(JCC) * CUT_CELL(ICC)%ZZ(N,JCC) ! Known rho*zz^n
         ENDDO
      ENDDO CUTCELL_LOOP

   ELSE

      ! Loop on Cartesian Cells:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (MESHES(NM)%CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Cycle Reg cells not implicit, cut-cells
                                                                ! underlying Cartesian cells and
                                                                ! solid cells.

               ! Cut-cells are surrounded by a layer of GASPHASE cells which is
               ! also integrated implicitly.
               IROW_LOC = MESHES(NM)%CCVAR(I,J,K,IBM_UNKZ) - UNKZ_IND(NM_START)
               !RZ_Z(IROW_LOC) = 0.5_EB*(RHO(I,J,K)*ZZ(I,J,K,N)+RHOS(I,J,K)*ZZS(I,J,K,N)) ! Known rho*zz

               RZ_Z(IROW_LOC) = 0.5_EB*(MESHES(NM)%RHO_ZZN(I,J,K,N)+RHOS(I,J,K)*ZZS(I,J,K,N))
               RZ_ZS(IROW_LOC)= RHOS(I,J,K)*ZZS(I,J,K,N)

            ENDDO
         ENDDO
      ENDDO

      ! Now loop Cut-cells:
      CUTCELL_LOOP2 : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         IF( SOLID(CELL_INDEX(CUT_CELL(ICC)%IJK(IAXIS),CUT_CELL(ICC)%IJK(JAXIS),CUT_CELL(ICC)%IJK(KAXIS))) ) CYCLE
         DO JCC=1,CUT_CELL(ICC)%NCELL
            IROW_LOC = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            RZ_Z(IROW_LOC) = 0.5_EB*(CUT_CELL(ICC)%RHO(JCC) *CUT_CELL(ICC)%ZZ(N,JCC) + &
                                     CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC))
            RZ_ZS(IROW_LOC)=CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC)
         ENDDO
      ENDDO CUTCELL_LOOP2

   ENDIF

ENDDO MESH_LOOP


RETURN
END SUBROUTINE GET_RHOZZVECTOR_SCALAR_3D


! -------------------- GET_ADV_TRANSPIRATIONVECTOR_SCALAR_3D --------------------

SUBROUTINE GET_ADV_TRANSPIRATIONVECTOR_SCALAR_3D(N)

INTEGER, INTENT(IN) :: N

! Local Variables:
INTEGER :: NM,I,J,K,ICC,JCC,ICF,ICF2,IFC,IFACE,NFACE,IROW_LOC
REAL(EB):: AREAI

! Loop meshes:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN

      ! First Cycle over cut-cell underlying Cartesian cells:
      ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH

         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF( SOLID(CELL_INDEX(I,J,K)) ) CYCLE

         ! Now Define total area of INBOUNDARY cut-faces:
         ICF=CCVAR(I,J,K,IBM_IDCF);
         IF (ICF <= 0) CYCLE
         NFACE = CUT_FACE(ICF)%NFACE
         DO JCC =1,CUT_CELL(ICC)%NCELL
            IROW_LOC = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            IFC_LOOP : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)

               IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)

               IF (CUT_CELL(ICC)%FACE_LIST(1,IFACE) == IBM_FTYPE_CFINB) THEN
                  ICF2   = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
                  IFACE  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
                  AREAI = CUT_FACE(ICF)%AREA(IFACE)
                  F_Z(IROW_LOC) = F_Z(IROW_LOC) + AREAI*CUT_FACE(ICF)%VEL(IFACE) * &
                                  CUT_CELL(ICC)%RHO(JCC)*CUT_CELL(ICC)%ZZ(N,JCC)
               ENDIF

            ENDDO IFC_LOOP
         ENDDO
      ENDDO ICC_LOOP

   ELSE ! Corrector

      ! First Cycle over cut-cell underlying Cartesian cells:
      ICC_LOOP2 : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH

         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         IF( SOLID(CELL_INDEX(I,J,K)) ) CYCLE

         ! Now Define total area of INBOUNDARY cut-faces:
         ICF=CCVAR(I,J,K,IBM_IDCF);
         IF (ICF <= 0) CYCLE
         NFACE = CUT_FACE(ICF)%NFACE
         DO JCC =1,CUT_CELL(ICC)%NCELL
            IROW_LOC = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
            IFC_LOOP2 : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)

               IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)

               IF (CUT_CELL(ICC)%FACE_LIST(1,IFACE) == IBM_FTYPE_CFINB) THEN
                  ICF2   = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
                  IFACE  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
                  AREAI = CUT_FACE(ICF)%AREA(IFACE)
                  F_Z(IROW_LOC) = F_Z(IROW_LOC) + AREAI*CUT_FACE(ICF)%VELS(IFACE) * &
                                  CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC)
               ENDIF

            ENDDO IFC_LOOP2
         ENDDO
      ENDDO ICC_LOOP2

   ENDIF ! PREDICTOR

ENDDO MESH_LOOP

RETURN
END SUBROUTINE GET_ADV_TRANSPIRATIONVECTOR_SCALAR_3D

! ------------------------- GET_ADVDIFFVECTOR_SCALAR_3D -------------------------

SUBROUTINE GET_ADVDIFFVECTOR_SCALAR_3D(N)

INTEGER, INTENT(IN) :: N

! Local Variables:
INTEGER :: NM,I,J,K
REAL(EB):: PRFCT
INTEGER :: X1AXIS,IFACE,IND(LOW_IND:HIGH_IND),IND_LOC(LOW_IND:HIGH_IND),ICF,IND1,IND2,IOR
INTEGER :: LOCROW_1,LOCROW_2,ILOC,IROW,ICC,JCC,ISIDE,IW
REAL(EB):: AF,KFACE(2,2),F_LOC(2),CIJP,CIJM,VELC,ALPHAP1,AM_P1,AP_P1,RHO_Z,FN_ZZ,FCT
REAL(EB), POINTER, DIMENSION(:,:,:)  :: RHOP=>NULL(),UP=>NULL(),VP=>NULL(),WP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:)::  ZZP=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()
TYPE(CFACE_TYPE), POINTER :: CFA=>NULL()
TYPE(IBM_REGFACEZ_TYPE),  POINTER, DIMENSION(:) :: REGFACE_Z=>NULL()
LOGICAL :: DO_LO,DO_HI

! This routine computes RHS due to boundary conditions prescribed in immersed solids
! and domain boundaries.

! First Domain Boundaries:
! Mesh Loop, Advective Fluxes:
MESH_LOOP_DBND : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   IF (PREDICTOR) THEN
      ZZP  => ZZ
      RHOP => RHO
      UP   => U
      VP   => V
      WP   => W
      PRFCT= 1._EB
   ELSE
      ZZP  => ZZS
      RHOP => RHOS
      UP   => US
      VP   => VS
      WP   => WS
      PRFCT= 0._EB
   ENDIF

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.

   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.

   ! First add advective fluxes to domain boundary regular and cut-cells:
   ! IAXIS faces:
   X1AXIS = IAXIS
   REGFACE_Z => IBM_REGFACE_IAXIS_Z
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      I    = REGFACE_Z(IFACE)%IJK(IAXIS)
      J    = REGFACE_Z(IFACE)%IJK(JAXIS)
      K    = REGFACE_Z(IFACE)%IJK(KAXIS)
      DO_LO= REGFACE_Z(IFACE)%DO_LO_IND
      DO_HI= REGFACE_Z(IFACE)%DO_HI_IND
      ! Unknowns on related cells:
      IND_LOC(LOW_IND) = CCVAR(I  ,J,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= CCVAR(I+1,J,K,IBM_UNKZ) - UNKZ_IND(NM_START)

      AF = DY(J)*DZ(K)
      IF (DO_LO) F_Z(IND_LOC( LOW_IND)) = F_Z(IND_LOC( LOW_IND)) + REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
      IF (DO_HI) F_Z(IND_LOC(HIGH_IND)) = F_Z(IND_LOC(HIGH_IND)) - REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
   ENDDO

   ! JAXIS faces:
   X1AXIS = JAXIS
   REGFACE_Z => IBM_REGFACE_JAXIS_Z
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      I     = REGFACE_Z(IFACE)%IJK(IAXIS)
      J     = REGFACE_Z(IFACE)%IJK(JAXIS)
      K     = REGFACE_Z(IFACE)%IJK(KAXIS)
      DO_LO = REGFACE_Z(IFACE)%DO_LO_IND
      DO_HI = REGFACE_Z(IFACE)%DO_HI_IND
      ! Unknowns on related cells:
      IND_LOC(LOW_IND) = CCVAR(I,J  ,K,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= CCVAR(I,J+1,K,IBM_UNKZ) - UNKZ_IND(NM_START)

      AF = DX(I)*DZ(K)
      IF (DO_LO) F_Z(IND_LOC( LOW_IND)) = F_Z(IND_LOC( LOW_IND)) + REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
      IF (DO_HI) F_Z(IND_LOC(HIGH_IND)) = F_Z(IND_LOC(HIGH_IND)) - REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
   ENDDO

   ! KAXIS faces:
   X1AXIS = KAXIS
   REGFACE_Z => IBM_REGFACE_KAXIS_Z
   DO IFACE=1,MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)
      IW = REGFACE_Z(IFACE)%IWC
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE
      I     = REGFACE_Z(IFACE)%IJK(IAXIS)
      J     = REGFACE_Z(IFACE)%IJK(JAXIS)
      K     = REGFACE_Z(IFACE)%IJK(KAXIS)
      DO_LO = REGFACE_Z(IFACE)%DO_LO_IND
      DO_HI = REGFACE_Z(IFACE)%DO_HI_IND
      ! Unknowns on related cells:
      IND_LOC(LOW_IND) = CCVAR(I,J,K  ,IBM_UNKZ) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= CCVAR(I,J,K+1,IBM_UNKZ) - UNKZ_IND(NM_START)

      AF = DX(I)*DY(J)
      IF (DO_LO) F_Z(IND_LOC( LOW_IND)) = F_Z(IND_LOC( LOW_IND)) + REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
      IF (DO_HI) F_Z(IND_LOC(HIGH_IND)) = F_Z(IND_LOC(HIGH_IND)) - REGFACE_Z(IFACE)%RHOZZ_U(N)*AF
   ENDDO

   IF (NEW_SCALAR_TRANSPORT) THEN

   ! Boundary Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   IFACE_LOOP_RCF1: DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z

      IW=MESHES(NM)%IBM_RCFACE_Z(IFACE)%IWC
      WC=>WALL(IW); IF ( WC%BOUNDARY_TYPE==NULL_BOUNDARY ) CYCLE IFACE_LOOP_RCF1

      I      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
      J      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
      K      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(LOW_IND)
      IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(HIGH_IND)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKZ_IND(NM_START)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND

      IOR = WC%ONE_D%IOR
      ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ILOC=1,
      !                              when sign of IOR is  1 -> use High Side cell -> ILOC=2.
      ILOC = 1 + (SIGN(1,IOR)+1) / 2
      ! First (rho hs)_i,j,k:
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         AF = DY(J)*DZ(K)
         VELC = UP(I,J,K)
      CASE(JAXIS)
         AF = DX(I)*DZ(K)
         VELC = VP(I,J,K)
      CASE(KAXIS)
         AF = DX(I)*DY(J)
         VELC = WP(I,J,K)
      END SELECT
      FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! These have been Flux limited in wall.f90
      SELECT CASE(WC%BOUNDARY_TYPE)
         CASE DEFAULT
            ! Already filled in previous X1AXIS select case.
         CASE(SOLID_BOUNDARY)
            IF (PREDICTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL_S
            IF (CORRECTOR) VELC = -SIGN(1._EB,REAL(IOR,EB))*WC%ONE_D%U_NORMAL
         CASE(INTERPOLATED_BOUNDARY)
            VELC = UVW_SAVE(IW)
      END SELECT

      IROW=IND_LOC(ILOC)   ! Process Local Unknown number.
      FCT = REAL(3-2*ILOC,EB)
      F_Z(IROW) = F_Z(IROW) + FCT*FN_ZZ*VELC*AF

   ENDDO IFACE_LOOP_RCF1

   ! Now Boundary Gasphase CUT_FACES:
   ICF_LOOP1: DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
      IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE ICF_LOOP1
      IW=MESHES(NM)%CUT_FACE(ICF)%IWC
      WC=>WALL(IW); IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY ) CYCLE ICF_LOOP1
      IOR = WC%ONE_D%IOR
      FN_ZZ           = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! These have been Flux limited in wall.f90
      ! This expression is such that when sign of IOR is -1 -> use Low Side cell  -> ILOC=1,
      !                              when sign of IOR is  1 -> use High Side cell -> ILOC=2 .
      ILOC = 1 + (SIGN(1,IOR)+1) / 2
      DO IFACE=1,CUT_FACE(ICF)%NFACE
         AF   = CUT_FACE(ICF)%AREA(IFACE)
         VELC = PRFCT*CUT_FACE(ICF)%VEL(IFACE) + (1._EB-PRFCT)*CUT_FACE(ICF)%VELS(IFACE)
         ! Unknowns on related cells:
         IND_LOC(ILOC) = MESHES(NM)%CUT_FACE(ICF)%UNKZ(ILOC,IFACE) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
         ! First (rho hs)_i,j,k:
         IF (CUT_FACE(ICF)%CELL_LIST(1,ILOC,IFACE) == IBM_FTYPE_CFGAS) THEN
            IROW=IND_LOC(ILOC)   ! Process Local Unknown number.
            FCT = REAL(3-2*ILOC,EB)
            F_Z(IROW) = F_Z(IROW) + FCT*FN_ZZ*VELC*AF
         ENDIF
      ENDDO ! IFACE

   ENDDO ICF_LOOP1

   ELSE ! NEW_SCALAR_TRANSPORT

   ! Boundary Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   IFACE_LOOP_RCF: DO IFACE=1,MESHES(NM)%IBM_NBBRCFACE_Z

      IW=MESHES(NM)%IBM_RCFACE_Z(IFACE)%IWC
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE IFACE_LOOP_RCF

      I      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(IAXIS)
      J      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(JAXIS)
      K      = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%IBM_RCFACE_Z(IFACE)%IJK(KAXIS+1)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(LOW_IND)
      IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_Z(IFACE)%UNK(HIGH_IND)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKZ_IND(NM_START)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      AXIS_SELECT: SELECT CASE(X1AXIS)
         CASE(IAXIS)
            AF = DY(J)*DZ(K)
            ! Advective Part: Velocity u
            VELC = UP(I,J,K)
            IF ( I == ILO_FACE ) THEN
               LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
               F_LOC(1) = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! For low side use Wall values defined in wall.f90.
               F_LOC(2) = RHOP(I+1,J,K)*ZZP(I+1,J,K,N)
            ENDIF
            IF ( I == IHI_FACE ) THEN
               LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
               F_LOC(1) = RHOP(I  ,J,K)*ZZP(I  ,J,K,N)
               F_LOC(2) = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! For high side use Wall values defined in wall.f90.
            ENDIF
         CASE(JAXIS)
            AF = DX(I)*DZ(K)
            ! Advective Part: Velocity v
            VELC = VP(I,J,K)
            IF ( J == JLO_FACE ) THEN
               LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
               F_LOC(1) = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! For low side use Wall values defined in wall.f90.
               F_LOC(2) = RHOP(I,J+1,K)*ZZP(I,J+1,K,N)
            ENDIF
            IF ( J == JHI_FACE ) THEN
               LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
               F_LOC(1) = RHOP(I,J  ,K)*ZZP(I,J  ,K,N)
               F_LOC(2) = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! For high side use Wall values defined in wall.f90.
            ENDIF
         CASE(KAXIS)
            AF = DX(I)*DY(J)
            ! Advective Part: Velocity w
            VELC = WP(I,J,K)
            IF ( K == KLO_FACE ) THEN
               LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
               F_LOC(1) = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! For low side use Wall values defined in wall.f90.
               F_LOC(2) = RHOP(I,J,K+1)*ZZP(I,J,K+1,N)
            ENDIF
            IF ( K == KHI_FACE ) THEN
               LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
               F_LOC(1) = RHOP(I,J,K  )*ZZP(I,J,K  ,N)
               F_LOC(2) = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) ! For high side use Wall values defined in wall.f90.
            ENDIF
      ENDSELECT AXIS_SELECT

      ! Matrix coefficients, Next to domain boundary always Godunov:
      ALPHAP1 = SIGN( 1._EB, VELC)
      AM_P1 = 0.5_EB*(1._EB+ALPHAP1)
      AP_P1 = 0.5_EB*(1._EB-ALPHAP1)
      CIJM = AM_P1*VELC*AF
      CIJP = AP_P1*VELC*AF

      ! Now add to A corresponding advection and diffusion coeffs:
      !    Cols 1,2: ind(LOW_IND) ind(HIGH_IND), Rows 1,2: ind_loc(LOW_IND) ind_loc(HIGH_IND)
      KFACE(1,1) = CIJM; KFACE(2,1) =-CIJM; KFACE(1,2) = CIJP; KFACE(2,2) =-CIJP

      DO ISIDE=1,2
         IF ( MESHES(NM)%IBM_RCFACE_Z(IFACE)%CELL_LIST(1,ISIDE) == IBM_FTYPE_CFGAS ) THEN
            ! Discard if cut-cell on guard-cell region (External domain boundary):
            ICC = MESHES(NM)%IBM_RCFACE_Z(IFACE)%CELL_LIST(2,ISIDE); IF (ICC > MESHES(NM)%N_CUTCELL_MESH) CYCLE
            JCC = MESHES(NM)%IBM_RCFACE_Z(IFACE)%CELL_LIST(3,ISIDE)
            F_LOC(ISIDE) =       PRFCT *CUT_CELL(ICC)% RHO(JCC)*CUT_CELL(ICC)% ZZ(N,JCC) + &
                          (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC)
         ENDIF
      ENDDO

      DO ILOC=LOCROW_1,LOCROW_2 ! Local row number in Kface
         IROW=IND_LOC(ILOC)   ! Process Local Unknown number.
         F_Z(IROW) = F_Z(IROW) + KFACE(ILOC,1)*F_LOC(1) + KFACE(ILOC,2)*F_LOC(2)
      ENDDO

   ENDDO IFACE_LOOP_RCF

   ! Now Boundary Gasphase CUT_FACES:
   ICF_LOOP: DO ICF = 1,MESHES(NM)%N_BBCUTFACE_MESH
      IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE ICF_LOOP
      IW=MESHES(NM)%CUT_FACE(ICF)%IWC
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY         .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) CYCLE ICF_LOOP
      I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
      J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
      K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)
      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
         CASE(JAXIS)
            IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
         CASE(KAXIS)
            IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row, i.e. in the current mesh.
            IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row, i.e. in the current mesh.
      ENDSELECT

      IFACE_LOOP_GCF: DO IFACE=1,MESHES(NM)%CUT_FACE(ICF)%NFACE

         ! Unknowns on related cells:
         IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKZ(LOW_IND,IFACE)
         IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKZ(HIGH_IND,IFACE)

         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKZ_IND(NM_START) ! All row indexes must refer to ind_loc.
         IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKZ_IND(NM_START)

         AF = MESHES(NM)%CUT_FACE(ICF)%AREA(IFACE)

         ! Matrix coefficients for advection:
         VELC =        PRFCT *MESHES(NM)%CUT_FACE(ICF)%VEL(IFACE) + &
                (1._EB-PRFCT)*MESHES(NM)%CUT_FACE(ICF)%VELS(IFACE)

         ALPHAP1 = SIGN( 1._EB, VELC)
         AM_P1 = 0.5_EB*(1._EB+ALPHAP1)
         AP_P1 = 0.5_EB*(1._EB-ALPHAP1)
         CIJM = AM_P1*VELC*AF
         CIJP = AP_P1*VELC*AF

         ! Now add to A corresponding advection and diffusion coeffs:
         !    Cols 1,2: ind(LOW_IND) ind(HIGH_IND), Rows 1,2: ind_loc(LOW_IND) ind_loc(HIGH_IND)
         KFACE(1,1) = CIJM; KFACE(2,1) =-CIJM; KFACE(1,2) = CIJP; KFACE(2,2) =-CIJP

         F_LOC(:) = WC%ONE_D%RHO_F*WC%ONE_D%ZZ_F(N) !Initialize both sides to face BC value.
         ISIDE_LOOP: DO ISIDE=1,2
            SELECT CASE(MESHES(NM)%CUT_FACE(ICF)%CELL_LIST(1,ISIDE,IFACE))
            CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
               ! If cut-cell on guard-cell region, skip, will use BC value.
               ICC = MESHES(NM)%CUT_FACE(ICF)%CELL_LIST(2,ISIDE,IFACE); IF(ICC>MESHES(NM)%N_CUTCELL_MESH) CYCLE ISIDE_LOOP
               JCC = MESHES(NM)%CUT_FACE(ICF)%CELL_LIST(3,ISIDE,IFACE)
               F_LOC(ISIDE) =       PRFCT *CUT_CELL(ICC)% RHO(JCC)*CUT_CELL(ICC)% ZZ(N,JCC) + &
                             (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC)
            END SELECT
         ENDDO ISIDE_LOOP

         DO ILOC=LOCROW_1,LOCROW_2 ! Local row number in Kface
           IROW=IND_LOC(ILOC)     ! Process Local Unknown number.
           F_Z(IROW) = F_Z(IROW) + KFACE(ILOC,1)*F_LOC(1) + KFACE(ILOC,2)*F_LOC(2)
         ENDDO

      ENDDO IFACE_LOOP_GCF

   ENDDO ICF_LOOP

   ENDIF ! NEW_SCALAR_TRANSPORT

   ! INBOUNDARY cut-faces, loop on CFACE to add BC defined at SOLID phase:
   DO ICF=1,N_CFACE_CELLS
      CFA  => CFACE(ICF)
      IND1 = CFA%CUT_FACE_IND1;                         IND2 = CFA%CUT_FACE_IND2
      ICC  = CUT_FACE(IND1)%CELL_LIST(2,LOW_IND,IND2);  JCC  = CUT_FACE(IND1)%CELL_LIST(3,LOW_IND,IND2)
      IROW = CUT_CELL(ICC)%UNKZ(JCC) - UNKZ_IND(NM_START)
      IF (PREDICTOR) THEN
         VELC = CFA%ONE_D%U_NORMAL
      ELSE
         VELC = CFA%ONE_D%U_NORMAL_S
      ENDIF
      IF (VELC>0._EB) THEN
         RHO_Z = PRFCT *CUT_CELL(ICC)% RHO(JCC)*CUT_CELL(ICC)% ZZ(N,JCC) + &
          (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)*CUT_CELL(ICC)%ZZS(N,JCC)
      ELSE
         RHO_Z = CFA%ONE_D%RHO_F*CFA%ONE_D%ZZ_F(N)
      ENDIF
      F_Z(IROW) = F_Z(IROW) + RHO_Z*VELC*CFA%AREA
   ENDDO

   ! Then add diffusive fluxes through domain boundaries:
   ! Defined in CCREGION_DIVERGENCE_PART_1.

ENDDO MESH_LOOP_DBND



! Source due to nonzero velocities in SOLID-CUT CELL interface faces:
! This is only nonzero when the Poisson solve is done s.t. PRES_ON_WHOLE_DOMAIN = .TRUE. (Solver 'FFT','GLMAT')
IF (PRES_ON_WHOLE_DOMAIN) CALL GET_ADV_TRANSPIRATIONVECTOR_SCALAR_3D(N) ! add to F_Z

RETURN
END SUBROUTINE GET_ADVDIFFVECTOR_SCALAR_3D


! ---------------------------- CCIBM_VELOCITY_BC -------------------------------

SUBROUTINE CCIBM_VELOCITY_BC(T,NM,APPLY_TO_ESTIMATED_VARIABLES)

USE TURBULENCE, ONLY : WALL_MODEL
USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY
REAL(EB), INTENT(IN) :: T
INTEGER, INTENT(IN) :: NM
LOGICAL, INTENT(IN) :: APPLY_TO_ESTIMATED_VARIABLES

! Local Variables:
INTEGER :: IEDGE,EP,INPE,VIND
INTEGER :: II,JJ,KK,IE,IEC,I_SGN,ICD,ICD_SGN,IIF,JJF,KKF,FAXIS,ICDO,ICDO_SGN,IS
REAL(EB), ALLOCATABLE, DIMENSION(:,:,:) :: UVW_EP
REAL(EB), ALLOCATABLE, DIMENSION(:,:,:,:) :: DUVW_EP
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU=>NULL(),VV=>NULL(),WW=>NULL(),RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
REAL(EB) :: NU,MU_FACE,RHO_FACE,DXN_STRM_UB,SLIP_FACTOR,SRGH,U_TAU,Y_PLUS,TNOW,MU_EP,MU_DUIDXJ_USE(2),DUIDXJ_USE(2),&
            DUIDXJ(-2:2),MU_DUIDXJ(-2:2),DXX(2),DF, DE, UE, UF, UB
TYPE(IBM_EDGE_TYPE), POINTER :: IBM_EDGE
LOGICAL :: IS_RCEDGE

TNOW = T
TNOW = CURRENT_TIME()

IF (APPLY_TO_ESTIMATED_VARIABLES) THEN
   UU   => US
   VV   => VS
   WW   => WS
   ZZP  => ZZS
   RHOP => RHOS
ELSE
   UU   => U
   VV   => V
   WW   => W
   ZZP  => ZZ
   RHOP => RHO
ENDIF

ALLOCATE(UVW_EP(IAXIS:KAXIS,0:INT_N_EXT_PTS,0:0))
ALLOCATE(DUVW_EP(IAXIS:KAXIS,IAXIS:KAXIS,0:INT_N_EXT_PTS,0:0))

! Compute initial DUIDXJ, MUDUIDXJ in RCEDGES:
IS_RCEDGE = .TRUE.
RCEDGE_LOOP_1 : DO IEDGE=1,MESHES(NM)%IBM_NRCEDGE
   IBM_EDGE => IBM_RCEDGE(IEDGE)
   CALL IBM_RCEDGE_DUIDXJ
ENDDO RCEDGE_LOOP_1

! Wall Model to compute DUIDXJ, MUDUIDXJ in boundary B, extrapolate from External point and B to IBEDGE and compute TAU, OMG.
IS_RCEDGE = .FALSE.
IBEDGE_LOOP_1 : DO IEDGE=1,MESHES(NM)%IBM_NIBEDGE
   IBM_EDGE => IBM_IBEDGE(IEDGE)
   CALL IBM_EDGE_TAU_OMG
ENDDO IBEDGE_LOOP_1

! Recompute DUIDXJ, MUDUIDXJ in RCEDGES if needed:
IS_RCEDGE = .TRUE.
RCEDGE_LOOP_2 : DO IEDGE=1,MESHES(NM)%IBM_NRCEDGE
   IBM_EDGE => IBM_RCEDGE(IEDGE)
   CALL IBM_RCEDGE_TAU_OMG
ENDDO RCEDGE_LOOP_2

DEALLOCATE(UVW_EP,DUVW_EP)

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW

RETURN

CONTAINS

SUBROUTINE IBM_RCEDGE_DUIDXJ

INTEGER :: IOE
REAL(EB):: VEL_GAS(-2:2),XB_IB(-2:2),MU_RC,DEL_RC,UB,U1,BFC,CFC

IE = IBM_EDGE%IE
II     = IJKE( 1,IE)
JJ     = IJKE( 2,IE)
KK     = IJKE( 3,IE)
IEC= IJKE( 4,IE) ! IEC is the edges X1AXIS

VEL_GAS(-2:2) = 0._EB; XB_IB(-2:2) = 0._EB
ORIENTATION_LOOP: DO IS=1,3
   IF (IS==IEC) CYCLE ORIENTATION_LOOP
   SIGN_LOOP: DO I_SGN=-1,1,2

      ! Determine Index_Coordinate_Direction
      ! IEC=1, ICD=1 refers to DWDY; ICD=2 refers to DVDZ
      ! IEC=2, ICD=1 refers to DUDZ; ICD=2 refers to DWDX
      ! IEC=3, ICD=1 refers to DVDX; ICD=2 refers to DUDY

      IF (IS>IEC) ICD = IS-IEC
      IF (IS<IEC) ICD = IS-IEC+3
      ICD_SGN = I_SGN * ICD

      ! With ICD_SGN check if face:
      ! IBEDGE IEC=IAXIS => ICD_SGN=-2 => FACE  low Z normal to JAXIS.
      !                     ICD_SGN=-1 => FACE  low Y normal to KAXIS.
      !                     ICD_SGN= 1 => FACE high Y normal to KAXIS.
      !                     ICD_SGN= 2 => FACE high Z normal to JAXIS.
      ! IBEDGE IEC=JAXIS => ICD_SGN=-2 => FACE  low X normal to KAXIS.
      !                     ICD_SGN=-1 => FACE  low Z normal to IAXIS.
      !                     ICD_SGN= 1 => FACE high Z normal to IAXIS.
      !                     ICD_SGN= 2 => FACE high X normal to KAXIS.
      ! IBEDGE IEC=KAXIS => ICD_SGN=-2 => FACE  low Y normal to IAXIS.
      !                     ICD_SGN=-1 => FACE  low X normal to JAXIS.
      !                     ICD_SGN= 1 => FACE high X normal to JAXIS.
      !                     ICD_SGN= 2 => FACE high Y normal to IAXIS.
      ! is GASPHASE cut-face.
      XB_IB(ICD_SGN) = IBM_EDGE%XB_IB(ICD_SGN)
      IEC_SELECT: SELECT CASE(IEC)
         CASE(IAXIS)
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
               CASE( 1); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=KAXIS
               CASE( 2); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=JAXIS
            END SELECT
            IF (FAXIS==JAXIS) THEN
                VEL_GAS(ICD_SGN)   = VV(IIF,JJF,KKF)
            ELSE ! IF(FAXIS==KAXIS) THEN
                VEL_GAS(ICD_SGN)   = WW(IIF,JJF,KKF)
            ENDIF

         CASE(JAXIS)
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
               CASE( 1); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=IAXIS
               CASE( 2); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
            END SELECT
            IF (FAXIS==KAXIS) THEN
               VEL_GAS(ICD_SGN)   = WW(IIF,JJF,KKF)
            ELSE ! IF(FAXIS==IAXIS) THEN
               VEL_GAS(ICD_SGN)   = UU(IIF,JJF,KKF)
            ENDIF

         CASE(KAXIS)
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE( 1); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE( 2); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=IAXIS
            END SELECT
            IF (FAXIS==IAXIS) THEN
               VEL_GAS(ICD_SGN)   = UU(IIF,JJF,KKF)
            ELSE ! IF(FAXIS==JAXIS) THEN
               VEL_GAS(ICD_SGN)   = VV(IIF,JJF,KKF)
            ENDIF

      END SELECT IEC_SELECT

      ! Divide distance to boundary (cut-face) or DXX (reg face) by 2 to get collocation point position:
      XB_IB(ICD_SGN) = XB_IB(ICD_SGN)/2._EB

   ENDDO SIGN_LOOP
ENDDO ORIENTATION_LOOP

SELECT CASE(IEC)
   CASE(IAXIS); MU_RC = 0.25_EB*(MU(II,JJ,KK)+MU(II,JJ+1,KK)+MU(II,JJ+1,KK+1)+MU(II,JJ,KK+1))
   CASE(JAXIS); MU_RC = 0.25_EB*(MU(II,JJ,KK)+MU(II+1,JJ,KK)+MU(II+1,JJ,KK+1)+MU(II,JJ,KK+1))
   CASE(KAXIS); MU_RC = 0.25_EB*(MU(II,JJ,KK)+MU(II+1,JJ,KK)+MU(II+1,JJ+1,KK)+MU(II,JJ+1,KK))
END SELECT

! IEC = IAXIS : DWDY (IOE=1), DVDZ (IOE=2):
! IEC = JAXIS : DUDZ (IOE=1), DWDX (IOE=2):
! IEC = KAXIS : DUDY (IOE=1), DVDX (IOE=2):
DO IOE = 1,2
   DEL_RC= XB_IB(-IOE)+XB_IB(IOE) ! Sum of 1/2*DY (IOE=1) or, 1/2*DZ (IOE=2), when IEC=IAXIS, etc.
   IBM_EDGE%DUIDXJ((/-IOE,IOE/))    = (VEL_GAS(IOE)-VEL_GAS(-IOE))/DEL_RC
   IBM_EDGE%MU_DUIDXJ((/-IOE,IOE/)) = MU_RC*IBM_EDGE%DUIDXJ((/-IOE,IOE/))
ENDDO

RETURN
END SUBROUTINE IBM_RCEDGE_DUIDXJ

SUBROUTINE IBM_RCEDGE_TAU_OMG

REAL(EB) :: MU_RC

IE = IBM_EDGE%IE
SIGN_LOOP_2: DO I_SGN=-1,1,2
   ORIENTATION_LOOP_2: DO ICD=1,2
      IF (ICD==1) THEN
         ICDO=2
      ELSE ! ICD=2
         ICDO=1
      ENDIF
      ICD_SGN = I_SGN*ICD
         DUIDXJ_USE(ICD) =   IBM_EDGE%DUIDXJ(ICD_SGN)
      MU_DUIDXJ_USE(ICD) = IBM_EDGE%MU_DUIDXJ(ICD_SGN)
      ICDO_SGN = I_SGN*ICDO
         DUIDXJ_USE(ICDO)=   IBM_EDGE%DUIDXJ(ICDO_SGN)
      MU_DUIDXJ_USE(ICDO)= IBM_EDGE%MU_DUIDXJ(ICDO_SGN)
      OME_E(ICD_SGN,IE) = DUIDXJ_USE(1) -    DUIDXJ_USE(2)
      TAU_E(ICD_SGN,IE) = MU_DUIDXJ_USE(1) + MU_DUIDXJ_USE(2)

   ENDDO ORIENTATION_LOOP_2
ENDDO SIGN_LOOP_2

! II     = IJKE( 1,IE)
! JJ     = IJKE( 2,IE)
! KK     = IJKE( 3,IE)
! IEC= IJKE( 4,IE) ! IEC is the edges X1AXIS
! IF(IEC==JAXIS) THEN
! WRITE(LU_ERR,*) 'RCE DUDZ=',IEDGE,II,JJ,KK,IBM_EDGE%DUIDXJ((/-1,1/)),':',(UU(II,JJ,KK+1)-UU(II,JJ,KK))/DZN(KK),',',UU(II,JJ,KK)
! WRITE(LU_ERR,*) 'RCE DWDX=',IEDGE,II,JJ,KK,IBM_EDGE%DUIDXJ((/-2,2/)),':',(WW(II+1,JJ,KK)-WW(II,JJ,KK))/DXN(II)
! WRITE(LU_ERR,*) 'RCE O=',IEDGE,II,JJ,KK,OME_E((/-2,-1,1,2/),IE),':',&
!                 (UU(II,JJ,KK+1)-UU(II,JJ,KK))/DZN(KK)-(WW(II+1,JJ,KK)-WW(II,JJ,KK))/DXN(II)
! MU_RC = 0.25_EB*(MU(II,JJ,KK)+MU(II+1,JJ,KK)+MU(II+1,JJ,KK+1)+MU(II,JJ,KK+1))
! WRITE(LU_ERR,*) 'RCE T=',IEDGE,II,JJ,KK,TAU_E((/-2,-1,1,2/),IE),':',&
!                 MU_RC*((UU(II,JJ,KK+1)-UU(II,JJ,KK))/DZN(KK)+(WW(II+1,JJ,KK)-WW(II,JJ,KK))/DXN(II))
! OME_E((/-2,-1,1,2/),IE) = (UU(II,JJ,KK+1)-UU(II,JJ,KK))/DZN(KK)-(WW(II+1,JJ,KK)-WW(II,JJ,KK))/DXN(II)
! TAU_E((/-2,-1,1,2/),IE) = MU_RC*((UU(II,JJ,KK+1)-UU(II,JJ,KK))/DZN(KK)+(WW(II+1,JJ,KK)-WW(II,JJ,KK))/DXN(II))
! ENDIF

RETURN
END SUBROUTINE IBM_RCEDGE_TAU_OMG

SUBROUTINE IBM_EDGE_TAU_OMG

REAL(EB) :: ADDV,VEL_T,VEL_GHOST,I_SGNR,I_SGN2,DUDXN,MU_DUDXN,MUA
INTEGER  :: IEP,JEP,KEP,SURF_INDEX,ITMP,SKIP_FCT,NPE_LIST_START,NPE_LIST_COUNT,IRCEDG,IRC,JRC,KRC
LOGICAL, PARAMETER :: WALL_MODEL_IN_NRMPLANE_TO_EDGE = .TRUE.
LOGICAL :: ALTERED_GRADIENT(-2:2)
REAL(EB):: XB_IB,OMEV_EP(-2:2),TAUV_EP(-2:2),DWDY,DVDZ,DUDZ,DWDX,DUDY,DVDX, &
           DUIDXJ_EP(-2:2),MU_DUIDXJ_EP(-2:2),EC_B(-2:2),EC_EP(-2:2),DEL_UB,DEL_EP,VEL_GAS,CEP,CB

REAL(EB):: DEL_EP1, DEL_EP2, AINV(2,2), UE1, UE2, B_POLY, C_POLY, USTR_1, USTR_2, ZETA

REAL(EB) :: VLG(-2:2),NUV(-2:2),RGH(-2:2),UTA(-2:2)
VLG(-2:2)=0._EB; NUV(-2:2)=0._EB; RGH(-2:2)=0._EB; UTA(-2:2)=0._EB

! Set these to zero for now:
VEL_T = 0._EB; SRGH = 0._EB

IE = IBM_EDGE%IE
II = IJKE( 1,IE)
JJ = IJKE( 2,IE)
KK = IJKE( 3,IE)
IEC= IJKE( 4,IE) ! IEC is the edges X1AXIS

! Loop over all possible orientations of edge and reassign velocity gradients if appropriate
EP=1
ALTERED_GRADIENT(-2:2) = .FALSE.
OMEV_EP(-2:2) = 0._EB; TAUV_EP(-2:2) = 0._EB; EC_B(-2:2) = 0._EB; EC_EP(-2:2) = 0._EB
DUIDXJ_EP(-2:2) = 0._EB; MU_DUIDXJ_EP(-2:2) = 0._EB; DUIDXJ(-2:2) = 0._EB; MU_DUIDXJ(-2:2) = 0._EB
ORIENTATION_LOOP: DO IS=1,3
   IF (IS==IEC) CYCLE ORIENTATION_LOOP
   SIGN_LOOP: DO I_SGN=-1,1,2

      ! Determine Index_Coordinate_Direction
      ! IEC=1, ICD=1 refers to DWDY; ICD=2 refers to DVDZ
      ! IEC=2, ICD=1 refers to DUDZ; ICD=2 refers to DWDX
      ! IEC=3, ICD=1 refers to DVDX; ICD=2 refers to DUDY

      IF (IS>IEC) ICD = IS-IEC
      IF (IS<IEC) ICD = IS-IEC+3
      ICD_SGN = I_SGN * ICD

      IF(.NOT.IBM_EDGE%PROCESS_EDGE_ORIENTATION(ICD_SGN)) CYCLE SIGN_LOOP

      ! With ICD_SGN check if face:
      ! IBEDGE IEC=IAXIS => ICD_SGN=-2 => FACE  low Z normal to JAXIS.
      !                     ICD_SGN=-1 => FACE  low Y normal to KAXIS.
      !                     ICD_SGN= 1 => FACE high Y normal to KAXIS.
      !                     ICD_SGN= 2 => FACE high Z normal to JAXIS.
      ! IBEDGE IEC=JAXIS => ICD_SGN=-2 => FACE  low X normal to KAXIS.
      !                     ICD_SGN=-1 => FACE  low Z normal to IAXIS.
      !                     ICD_SGN= 1 => FACE high Z normal to IAXIS.
      !                     ICD_SGN= 2 => FACE high X normal to KAXIS.
      ! IBEDGE IEC=KAXIS => ICD_SGN=-2 => FACE  low Y normal to IAXIS.
      !                     ICD_SGN=-1 => FACE  low X normal to JAXIS.
      !                     ICD_SGN= 1 => FACE high X normal to JAXIS.
      !                     ICD_SGN= 2 => FACE high Y normal to IAXIS.
      ! is GASPHASE cut-face.
      XB_IB      = IBM_EDGE%XB_IB(ICD_SGN) ! Coordinate centroid of IBEDGE resp to Boundary (note, either zero or negative).
      SURF_INDEX = IBM_EDGE%SURF_INDEX(ICD_SGN)
      IEC_SELECT: SELECT CASE(IEC)
         CASE(IAXIS) IEC_SELECT
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
               CASE( 1); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=KAXIS
               CASE( 2); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=JAXIS
            END SELECT
            IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP
            DXX(1)  = DY(JJF); DXX(2)  = DZ(KKF)

            ! Compute TAUV_EP, OMEV_EP, MU_FC, DXN_STRM_UB, VEL_GAS:
            SKIP_FCT = 1
            IF (FAXIS==JAXIS) THEN
               ITMP = MIN(5000,NINT(0.5_EB*(TMP(IIF,JJF,KKF)+TMP(IIF,JJF+1,KKF))))
               MU_FACE = MU_RSQMW_Z(ITMP,1)/RSQ_MW_Z(1)
               RHO_FACE = 0.5_EB*(  RHOP(IIF,JJF,KKF)+  RHOP(IIF,JJF+1,KKF))
               MUA = 0.5_EB*(MU(IIF,JJF,KKF) + MU(IIF,JJF+1,KKF))

               DXN_STRM_UB = DXX(2)
               ! Linear :
               DF     = DXX(2) - ABS(XB_IB)
               DE     = DXN_STRM_UB
               UF     = VV(IIF,JJF,KKF);  UE     = UF
               IF (.NOT.( (KKF+I_SGN>KBP1) .OR. (KKF+I_SGN<0) )) THEN
                  DE     = DZ(KKF+I_SGN) ! Should be one up from DXX(2).
                  UE     = VV(IIF,JJF,KKF+I_SGN)
               ENDIF
               UB     = VEL_T
               VEL_GAS  = 2._EB/(DF+DE)*((DE/2._EB+DF)*UF-DF/2._EB*UE) - 2._EB/(DF+DE)*(UF-UE)*(DXN_STRM_UB/2._EB)

               DEL_EP = DXX(2) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(2) ) THEN; SKIP_FCT = 2; DEL_EP = DEL_EP + DXX(2); ENDIF
               IEP=II; JEP=JJ; KEP=KK+SKIP_FCT*I_SGN

            ELSE ! IF(FAXIS==KAXIS) THEN
               ITMP = MIN(5000,NINT(0.5_EB*(TMP(IIF,JJF,KKF)+TMP(IIF,JJF,KKF+1))))
               MU_FACE = MU_RSQMW_Z(ITMP,1)/RSQ_MW_Z(1)
               RHO_FACE = 0.5_EB*(  RHOP(IIF,JJF,KKF)+  RHOP(IIF,JJF,KKF+1))
               MUA = 0.5_EB*(MU(IIF,JJF,KKF) + MU(IIF,JJF,KKF+1))

               DXN_STRM_UB = DXX(1)
               ! Linear :
               DF     = DXX(1) - ABS(XB_IB)
               DE     = DXN_STRM_UB
               UF     = WW(IIF,JJF,KKF);  UE     = UF
               IF (.NOT.( (JJF+I_SGN>JBP1) .OR. (JJF+I_SGN<0) )) THEN
                  DE     = DY(JJF+I_SGN) ! Should be one up from DXX(1).
                  UE     = WW(IIF,JJF+I_SGN,KKF)
               ENDIF
               UB     = VEL_T
               VEL_GAS  = 2._EB/(DF+DE)*((DE/2._EB+DF)*UF-DF/2._EB*UE) - 2._EB/(DF+DE)*(UF-UE)*(DXN_STRM_UB/2._EB)

               DEL_EP = DXX(1) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(1) ) THEN; SKIP_FCT = 2; DEL_EP = DEL_EP + DXX(1); ENDIF
               IEP=II; JEP=JJ+SKIP_FCT*I_SGN; KEP=KK

            ENDIF

            IF (IBM_EDGE%EDGE_IN_MESH(ICD_SGN)) THEN ! Regular computation of MU and velocity derivatives:
               MU_EP= 0.25_EB*(MU(IEP,JEP,KEP)+MU(IEP,JEP+1,KEP)+MU(IEP,JEP+1,KEP+1)+MU(IEP,JEP,KEP+1))
               IRCEDG = ECVAR(IEP,JEP,KEP,IBM_IDCE,IEC)
               IF (IRCEDG>0) THEN
                  DWDY = IBM_RCEDGE(IRCEDG)%DUIDXJ(1); DVDZ = IBM_RCEDGE(IRCEDG)%DUIDXJ(2)
               ELSE
                  DWDY = (WW(IEP,JEP+1,KEP)-WW(IEP,JEP,KEP))/DXX(1); DVDZ = (VV(IEP,JEP,KEP+1)-VV(IEP,JEP,KEP))/DXX(2)
               ENDIF
            ELSE
               MU_EP = 0._EB; DWDY = 0._EB; DVDZ = 0._EB
               ! First MU_EP:
               VIND=0
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               IF (NPE_LIST_COUNT>0) THEN
                 DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                    MU_EP = MU_EP + IBM_EDGE%INT_CVARS(INT_MU_IND,INPE)
                 ENDDO
                 MU_EP = MU_EP / REAL(NPE_LIST_COUNT,EB)
               ENDIF
               ! Then DWDY:
               VIND=KAXIS
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                  DWDY = DWDY + IBM_EDGE%INT_DCOEF(INPE,1)*IBM_EDGE%INT_FVARS(INT_VEL_IND,INPE)
               ENDDO
               ! Finally DVDZ:
               VIND=JAXIS
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                  DVDZ = DVDZ + IBM_EDGE%INT_DCOEF(INPE,1)*IBM_EDGE%INT_FVARS(INT_VEL_IND,INPE)
               ENDDO
            ENDIF

            OMEV_EP(ICD_SGN) = DWDY - DVDZ
            TAUV_EP(ICD_SGN) = MU_EP*(DWDY + DVDZ)
            IF (FAXIS==JAXIS) THEN
               DUIDXJ_EP(ICD_SGN)    = DVDZ
            ELSE ! IF(FAXIS==KAXIS) THEN
               DUIDXJ_EP(ICD_SGN)    = DWDY
            ENDIF

         CASE(JAXIS) IEC_SELECT
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
               CASE( 1); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=IAXIS
               CASE( 2); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
            END SELECT
            IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP
            DXX(1)  = DZ(KKF); DXX(2)  = DX(IIF)

            ! Compute TAUV_EP, OMEV_EP, MU_FC, DXN_STRM_UB, VEL_GAS:
            SKIP_FCT = 1
            IF (FAXIS==KAXIS) THEN
               ITMP = MIN(5000,NINT(0.5_EB*(TMP(IIF,JJF,KKF)+TMP(IIF,JJF,KKF+1))))
               MU_FACE = MU_RSQMW_Z(ITMP,1)/RSQ_MW_Z(1)
               RHO_FACE = 0.5_EB*(  RHOP(IIF,JJF,KKF)+  RHOP(IIF,JJF,KKF+1))
               MUA = 0.5_EB*(MU(IIF,JJF,KKF) +  MU(IIF,JJF,KKF+1))

               DXN_STRM_UB = DXX(2)
               ! Linear :
               DF     = DXX(2) - ABS(XB_IB)
               DE     = DXN_STRM_UB
               UF     = WW(IIF,JJF,KKF);  UE     = UF
               IF (.NOT.( (IIF+I_SGN>IBP1) .OR. (IIF+I_SGN<0) )) THEN
                  DE     = DX(IIF+I_SGN) ! Should be one up from DXX(2).
                  UE     = WW(IIF+I_SGN,JJF,KKF)
               ENDIF
               UB     = VEL_T
               VEL_GAS  = 2._EB/(DF+DE)*((DE/2._EB+DF)*UF-DF/2._EB*UE) - 2._EB/(DF+DE)*(UF-UE)*(DXN_STRM_UB/2._EB)

               DEL_EP = DXX(2) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(2) ) THEN; SKIP_FCT = 2; DEL_EP = DEL_EP + DXX(2); ENDIF
               IEP=II+SKIP_FCT*I_SGN; JEP=JJ; KEP=KK

            ELSE ! IF(FAXIS==IAXIS) THEN
               ITMP = MIN(5000,NINT(0.5_EB*(TMP(IIF,JJF,KKF)+TMP(IIF+1,JJF,KKF))))
               MU_FACE = MU_RSQMW_Z(ITMP,1)/RSQ_MW_Z(1)
               RHO_FACE = 0.5_EB*(  RHOP(IIF,JJF,KKF)+  RHOP(IIF+1,JJF,KKF))
               MUA = 0.5_EB*(MU(IIF,JJF,KKF) +  MU(IIF+1,JJF,KKF))

               DXN_STRM_UB = DXX(1)
               ! Linear :
               DF     = DXX(1) - ABS(XB_IB)
               DE     = DXN_STRM_UB
               UF     = UU(IIF,JJF,KKF);  UE     = UF
               IF (.NOT.( (KKF+I_SGN>KBP1) .OR. (KKF+I_SGN<0) )) THEN
                  DE     = DZ(KKF+I_SGN) ! Should be one up from DXX(1).
                  UE     = UU(IIF,JJF,KKF+I_SGN)
               ENDIF
               UB     = VEL_T
               VEL_GAS  = 2._EB/(DF+DE)*((DE/2._EB+DF)*UF-DF/2._EB*UE) - 2._EB/(DF+DE)*(UF-UE)*(DXN_STRM_UB/2._EB)

               DEL_EP = DXX(1) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(1) ) THEN; SKIP_FCT = 2; DEL_EP = DEL_EP + DXX(1); ENDIF
               IEP=II; JEP=JJ; KEP=KK+SKIP_FCT*I_SGN

            ENDIF

            IF (IBM_EDGE%EDGE_IN_MESH(ICD_SGN)) THEN ! Regular computation of MU and velocity derivatives:
               MU_EP= 0.25_EB*(MU(IEP,JEP,KEP)+MU(IEP+1,JEP,KEP)+MU(IEP+1,JEP,KEP+1)+MU(IEP,JEP,KEP+1))
               IRCEDG = ECVAR(IEP,JEP,KEP,IBM_IDCE,IEC)
               IF (IRCEDG>0) THEN
                  DUDZ = IBM_RCEDGE(IRCEDG)%DUIDXJ(1); DWDX = IBM_RCEDGE(IRCEDG)%DUIDXJ(2)
               ELSE
                  DUDZ = (UU(IEP,JEP,KEP+1)-UU(IEP,JEP,KEP))/DXX(1); DWDX = (WW(IEP+1,JEP,KEP)-WW(IEP,JEP,KEP))/DXX(2)
               ENDIF
            ELSE
               MU_EP = 0._EB; DUDZ = 0._EB; DWDX = 0._EB
               ! First MU_EP:
               VIND=0
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               IF (NPE_LIST_COUNT>0) THEN
                 DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                    MU_EP = MU_EP + IBM_EDGE%INT_CVARS(INT_MU_IND,INPE)
                 ENDDO
                 MU_EP = MU_EP / REAL(NPE_LIST_COUNT,EB)
               ENDIF
               ! Then DUDZ:
               VIND=IAXIS
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                  DUDZ = DUDZ + IBM_EDGE%INT_DCOEF(INPE,1)*IBM_EDGE%INT_FVARS(INT_VEL_IND,INPE)
               ENDDO
               ! Finally DWDX:
               VIND=KAXIS
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                  DWDX = DWDX + IBM_EDGE%INT_DCOEF(INPE,1)*IBM_EDGE%INT_FVARS(INT_VEL_IND,INPE)
               ENDDO
            ENDIF

            OMEV_EP(ICD_SGN) = DUDZ - DWDX
            TAUV_EP(ICD_SGN) = MU_EP*(DUDZ + DWDX)
            IF (FAXIS==KAXIS) THEN
               DUIDXJ_EP(ICD_SGN)    = DWDX
            ELSE ! IF(FAXIS==IAXIS) THEN
               DUIDXJ_EP(ICD_SGN)    = DUDZ
            ENDIF

            !  IF(NM==1 .AND. II==41 .AND. JJ==20 .AND. KK==32 .AND. FAXIS==IAXIS) THEN
            !    WRITE(LU_ERR,*) '>>>> ICD_SGN, FAXIS, VEL_GAS=',ICD_SGN,FAXIS,IEP,JEP,KEP
            !    WRITE(LU_ERR,*) '                          =',XB_IB,DXN_STRM_UB,ZETA,USTR_1,USTR_2,VEL_GAS
            !    WRITE(LU_ERR,*) 'DF,DE,UF,VV(IIF,JJF,KKF),UE,UB=',DF,DE,UF,UU(IIF,JJF,KKF),UE,UB
            !    WRITE(LU_ERR,*) 'ICD_SGN,DUIDXJ_EP(ICD_SGN)=',ICD_SGN,DUIDXJ_EP(ICD_SGN)
            !    WRITE(LU_ERR,*) 'DE,DEZ+1=',KKF,I_SGN,DZ(KKF),DZ(KKF+I_SGN)
            ! ENDIF

         CASE(KAXIS) IEC_SELECT
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE( 1); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE( 2); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=IAXIS
            END SELECT
            IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP
            DXX(1)  = DX(IIF); DXX(2)  = DY(JJF)

            ! Compute TAUV_EP, OMEV_EP, MU_FC, DXN_STRM_UB, VEL_GAS:
            SKIP_FCT = 1
            IF (FAXIS==IAXIS) THEN
               ITMP = MIN(5000,NINT(0.5_EB*(TMP(IIF,JJF,KKF)+TMP(IIF+1,JJF,KKF))))
               MU_FACE = MU_RSQMW_Z(ITMP,1)/RSQ_MW_Z(1)
               RHO_FACE = 0.5_EB*(  RHOP(IIF,JJF,KKF)+  RHOP(IIF+1,JJF,KKF))
               MUA = 0.5_EB*(MU(IIF,JJF,KKF) +  MU(IIF+1,JJF,KKF))

               DXN_STRM_UB = DXX(2)
               ! Linear :
               DF     = DXX(2) - ABS(XB_IB)
               DE     = DXN_STRM_UB
               UF     = UU(IIF,JJF,KKF);  UE     = UF
               IF (.NOT.( (JJF+I_SGN>JBP1) .OR. (JJF+I_SGN<0) )) THEN
                  DE     = DY(JJF+I_SGN) ! Should be one up from DXX(2).
                  UE     = UU(IIF,JJF+I_SGN,KKF)
               ENDIF
               UB     = VEL_T
               VEL_GAS  = 2._EB/(DF+DE)*((DE/2._EB+DF)*UF-DF/2._EB*UE) - 2._EB/(DF+DE)*(UF-UE)*(DXN_STRM_UB/2._EB)

               DEL_EP = DXX(2) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(2) ) THEN; SKIP_FCT = 2; DEL_EP = DEL_EP + DXX(2); ENDIF
               IEP=II; JEP=JJ+SKIP_FCT*I_SGN; KEP=KK

            ELSE ! IF(FAXIS==JAXIS) THEN
               ITMP = MIN(5000,NINT(0.5_EB*(TMP(IIF,JJF,KKF)+TMP(IIF,JJF+1,KKF))))
               MU_FACE = MU_RSQMW_Z(ITMP,1)/RSQ_MW_Z(1)
               RHO_FACE = 0.5_EB*(  RHOP(IIF,JJF,KKF)+  RHOP(IIF,JJF+1,KKF))
               MUA = 0.5_EB*(MU(IIF,JJF,KKF) +  MU(IIF,JJF+1,KKF))

               DXN_STRM_UB = DXX(1)
               ! Linear :
               DF     = DXX(1) - ABS(XB_IB)
               DE     = DXN_STRM_UB
               UF     = VV(IIF,JJF,KKF);  UE     = UF
               IF (.NOT.( (IIF+I_SGN>IBP1) .OR. (IIF+I_SGN<0) )) THEN
                  DE     = DX(IIF+I_SGN) ! Should be one up from DXX(1).
                  UE     = VV(IIF+I_SGN,JJF,KKF)
               ENDIF
               UB     = VEL_T
               VEL_GAS  = 2._EB/(DF+DE)*((DE/2._EB+DF)*UF-DF/2._EB*UE) - 2._EB/(DF+DE)*(UF-UE)*(DXN_STRM_UB/2._EB)

               DEL_EP = DXX(1) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(1) ) THEN; SKIP_FCT = 2; DEL_EP = DEL_EP + DXX(1); ENDIF
               IEP=II+SKIP_FCT*I_SGN; JEP=JJ; KEP=KK

            ENDIF

            IF (IBM_EDGE%EDGE_IN_MESH(ICD_SGN)) THEN ! Regular computation of MU and velocity derivatives:
               MU_EP= 0.25_EB*(MU(IEP,JEP,KEP)+MU(IEP+1,JEP,KEP)+MU(IEP+1,JEP+1,KEP)+MU(IEP,JEP+1,KEP))
               IRCEDG = ECVAR(IEP,JEP,KEP,IBM_IDCE,IEC)
               IF (IRCEDG>0) THEN
                  DVDX = IBM_RCEDGE(IRCEDG)%DUIDXJ(1); DUDY = IBM_RCEDGE(IRCEDG)%DUIDXJ(2)
               ELSE
                  DVDX = (VV(IEP+1,JEP,KEP)-VV(IEP,JEP,KEP))/DXX(1); DUDY = (UU(IEP,JEP+1,KEP)-UU(IEP,JEP,KEP))/DXX(2)
               ENDIF
            ELSE
               MU_EP = 0._EB; DVDX = 0._EB; DUDY = 0._EB
               ! First MU_EP:
               VIND=0
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               IF (NPE_LIST_COUNT>0) THEN
                 DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                    MU_EP = MU_EP + IBM_EDGE%INT_CVARS(INT_MU_IND,INPE)
                 ENDDO
                 MU_EP = MU_EP / REAL(NPE_LIST_COUNT,EB)
               ENDIF
               ! Then DVDX:
               VIND=JAXIS
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                  DVDX = DVDX + IBM_EDGE%INT_DCOEF(INPE,1)*IBM_EDGE%INT_FVARS(INT_VEL_IND,INPE)
               ENDDO
               ! Finally DUDY:
               VIND=IAXIS
               NPE_LIST_START = IBM_EDGE%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               NPE_LIST_COUNT = IBM_EDGE%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN)
               DO INPE=NPE_LIST_START+1,NPE_LIST_START+NPE_LIST_COUNT
                  DUDY = DUDY + IBM_EDGE%INT_DCOEF(INPE,1)*IBM_EDGE%INT_FVARS(INT_VEL_IND,INPE)
               ENDDO
            ENDIF

            OMEV_EP(ICD_SGN) = DVDX - DUDY
            TAUV_EP(ICD_SGN) = MU_EP*(DVDX + DUDY)
            IF (FAXIS==IAXIS) THEN
               DUIDXJ_EP(ICD_SGN)    = DUDY
            ELSE ! IF(FAXIS==JAXIS) THEN
               DUIDXJ_EP(ICD_SGN)    = DVDX
            ENDIF

      END SELECT IEC_SELECT

      ! Make collocated velocity point distance, half DELTA gas CF size:
      DXN_STRM_UB = DXN_STRM_UB/2._EB

      ! Define mu*Gradient:
      MU_DUIDXJ_EP(ICD_SGN) = MU_EP*DUIDXJ_EP(ICD_SGN)

      ALTERED_GRADIENT(ICD_SGN) = .TRUE.

      ! Here we have a cut-face, and OME and TAU in an external EDGE for extrapolation to IBEDGE.
      ! Now get value at the boundary using wall model:

      SELECT CASE(SURFACE(SURF_INDEX)%VELOCITY_BC_INDEX)
         CASE (FREE_SLIP_BC)
            VEL_GHOST = VEL_GAS
            DUIDXJ(ICD_SGN) = I_SGN*(VEL_GAS-VEL_GHOST)/(2._EB*DXN_STRM_UB)
            MU_DUIDXJ(ICD_SGN) = MUA*DUIDXJ(ICD_SGN)
         CASE (NO_SLIP_BC)
            VEL_GHOST = 2._EB*VEL_T - VEL_GAS
            DUIDXJ(ICD_SGN) = I_SGN*(VEL_GAS-VEL_GHOST)/(2._EB*DXN_STRM_UB)
            MU_DUIDXJ(ICD_SGN) = MUA*DUIDXJ(ICD_SGN)
         CASE (WALL_MODEL_BC)
            NU = MU_FACE/RHO_FACE
            CALL WALL_MODEL(SLIP_FACTOR,U_TAU,Y_PLUS,NU,SURFACE(SURF_INDEX)%ROUGHNESS,DXN_STRM_UB,VEL_GAS-VEL_T)
            ! Finally OME_E, TAU_E:
            ! SLIP_COEF = -1, no slip, VEL_GHOST=-VEL_GAS
            ! SLIP_COEF =  1, free slip, VEL_GHOST=VEL_T
            VEL_GHOST = VEL_T + 0.5_EB*(SLIP_FACTOR-1._EB)*(VEL_GAS-VEL_T)
            DUIDXJ(ICD_SGN) = REAL(I_SGN,EB)*(VEL_GAS-VEL_GHOST)/(2._EB*DXN_STRM_UB)
            MU_DUIDXJ(ICD_SGN) = RHO_FACE*U_TAU**2 * SIGN(1._EB,REAL(I_SGN,EB)*(VEL_GAS-VEL_T))
      END SELECT

      ! VLG(ICD_SGN)=VEL_GAS
      ! NUV(ICD_SGN)=MU_FACE  ! NU
      ! RGH(ICD_SGN)=RHO_FACE ! SURFACE(SURF_INDEX)%ROUGHNESS
      ! UTA(ICD_SGN)=U_TAU

      ! Extrapolation coefficients for the IBEDGE:
      EC_B(ICD_SGN) = (DEL_EP + ABS(XB_IB))/DEL_EP
      EC_EP(ICD_SGN)= 1._EB - EC_B(ICD_SGN)

      ! If needed re-interpolate stress and duidxj to RC EDGE:
      IEC_SELECT_2: SELECT CASE(IEC)
         CASE(IAXIS) IEC_SELECT_2
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
               CASE( 1); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=KAXIS
               CASE( 2); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=JAXIS
            END SELECT
            IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP
            DXX(1)  = DY(JJF); DXX(2)  = DZ(KKF)
            IF (FAXIS==JAXIS) THEN
               DEL_EP = DXX(2) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(2) ) THEN
                  DEL_EP = DEL_EP + DXX(2);
                  IRC=II; JRC=JJ; KRC=KK+I_SGN
                  IRCEDG = ECVAR(IRC,JRC,KRC,IBM_IDCE,IEC)
                  IF (IRCEDG>0) THEN
                     CEP = (DXX(2) - ABS(XB_IB))/DEL_EP; CB=DXX(2)/DEL_EP
                     IBM_RCEDGE(IRCEDG)%DUIDXJ((/ -ICD, ICD /))    = 0.5_EB*(IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN) + &
                                                                     CEP*   DUIDXJ_EP(ICD_SGN) + CB*   DUIDXJ(ICD_SGN))
                     IBM_RCEDGE(IRCEDG)%MU_DUIDXJ((/ -ICD, ICD /)) = 0.5_EB*(IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN) + &
                                                                     CEP*MU_DUIDXJ_EP(ICD_SGN) + CB*MU_DUIDXJ(ICD_SGN))
                  ENDIF
               ENDIF
            ELSE ! IF(FAXIS==KAXIS) THEN
               DEL_EP = DXX(1) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(1) ) THEN
                  DEL_EP = DEL_EP + DXX(1);
                  IRC=II; JRC=JJ+I_SGN; KRC=KK
                  IRCEDG = ECVAR(IRC,JRC,KRC,IBM_IDCE,IEC)
                  IF (IRCEDG>0) THEN
                     CEP = (DXX(1) - ABS(XB_IB))/DEL_EP; CB=DXX(1)/DEL_EP
                     IBM_RCEDGE(IRCEDG)%DUIDXJ((/ -ICD, ICD /))    = 0.5_EB*(IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN) + &
                                                                     CEP*   DUIDXJ_EP(ICD_SGN) + CB*   DUIDXJ(ICD_SGN))
                     IBM_RCEDGE(IRCEDG)%MU_DUIDXJ((/ -ICD, ICD /)) = 0.5_EB*(IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN) + &
                                                                     CEP*MU_DUIDXJ_EP(ICD_SGN) + CB*MU_DUIDXJ(ICD_SGN))
                  ENDIF
               ENDIF
            ENDIF
         CASE(JAXIS) IEC_SELECT_2
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
               CASE( 1); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=IAXIS
               CASE( 2); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
            END SELECT
            IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP
            DXX(1)  = DZ(KKF); DXX(2)  = DX(IIF)
            IF (FAXIS==KAXIS) THEN
               DEL_EP = DXX(2) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(2) ) THEN
                  DEL_EP = DEL_EP + DXX(2);
                  IRC=II+I_SGN; JRC=JJ; KRC=KK
                  IRCEDG = ECVAR(IRC,JRC,KRC,IBM_IDCE,IEC)
                  IF (IRCEDG>0) THEN
                     CEP = (DXX(2) - ABS(XB_IB))/DEL_EP; CB=DXX(2)/DEL_EP
                     IBM_RCEDGE(IRCEDG)%DUIDXJ((/ -ICD, ICD /))    = 0.5_EB*(IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN) + &
                                                                     CEP*   DUIDXJ_EP(ICD_SGN) + CB*   DUIDXJ(ICD_SGN))
                     IBM_RCEDGE(IRCEDG)%MU_DUIDXJ((/ -ICD, ICD /)) = 0.5_EB*(IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN) + &
                                                                     CEP*MU_DUIDXJ_EP(ICD_SGN) + CB*MU_DUIDXJ(ICD_SGN))
                  ENDIF
               ENDIF
            ELSE ! IF(FAXIS==IAXIS) THEN
               DEL_EP = DXX(1) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(1) ) THEN
                  DEL_EP = DEL_EP + DXX(1);
                  IRC=II; JRC=JJ; KRC=KK+I_SGN
                  IRCEDG = ECVAR(IRC,JRC,KRC,IBM_IDCE,IEC)
                  IF (IRCEDG>0) THEN
                     CEP = (DXX(1) - ABS(XB_IB))/DEL_EP; CB=DXX(1)/DEL_EP
                     ! WRITE(LU_ERR,*) ' '
                     ! WRITE(LU_ERR,*) 'EDGE JAXIS=',IRC,JRC,KRC,CEP,CB
                     ! WRITE(LU_ERR,*) 'OLD DUIDXJ=',IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN),IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN)
                     ! WRITE(LU_ERR,*) 'EP  DUIDXJ=',DUIDXJ_EP(ICD_SGN),MU_DUIDXJ_EP(ICD_SGN)
                     ! WRITE(LU_ERR,*) 'B   DUIDXJ=',DUIDXJ (ICD_SGN),MU_DUIDXJ (ICD_SGN)
                     IBM_RCEDGE(IRCEDG)%DUIDXJ((/ -ICD, ICD /))     = 0.5_EB*(IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN) + &
                                                                      CEP*   DUIDXJ_EP(ICD_SGN) + CB*   DUIDXJ(ICD_SGN))
                     IBM_RCEDGE(IRCEDG)%MU_DUIDXJ((/ -ICD, ICD /))  = 0.5_EB*(IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN) + &
                                                                      CEP*MU_DUIDXJ_EP(ICD_SGN) + CB*MU_DUIDXJ(ICD_SGN))
                     ! WRITE(LU_ERR,*) 'NEW   DUIDXJ=',IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN), IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN)
                     ! WRITE(LU_ERR,*) 'OTHER DUIDXJ=',IBM_RCEDGE(IRCEDG)%DUIDXJ(-ICD_SGN),IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(-ICD_SGN)
                  ENDIF
               ENDIF
            ENDIF
         CASE(KAXIS) IEC_SELECT_2
            ! Define Face indexes and normal axis FAXIS.
            SELECT CASE(ICD_SGN)
               CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
               CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE( 1); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
               CASE( 2); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=IAXIS
            END SELECT
            IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP
            DXX(1)  = DX(IIF); DXX(2)  = DY(JJF)

            IF (FAXIS==IAXIS) THEN
               DEL_EP = DXX(2) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(2) ) THEN
                  DEL_EP = DEL_EP + DXX(2);
                  IRC=II; JRC=JJ+I_SGN; KRC=KK
                  IRCEDG = ECVAR(IRC,JRC,KRC,IBM_IDCE,IEC)
                  IF (IRCEDG>0) THEN
                     CEP = (DXX(2) - ABS(XB_IB))/DEL_EP; CB=DXX(2)/DEL_EP
                     IBM_RCEDGE(IRCEDG)%DUIDXJ((/ -ICD, ICD /))    = 0.5_EB*(IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN) + &
                                                                     CEP*   DUIDXJ_EP(ICD_SGN) + CB*   DUIDXJ(ICD_SGN))
                     IBM_RCEDGE(IRCEDG)%MU_DUIDXJ((/ -ICD, ICD /)) = 0.5_EB*(IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN) + &
                                                                     CEP*MU_DUIDXJ_EP(ICD_SGN) + CB*MU_DUIDXJ(ICD_SGN))
                  ENDIF
               ENDIF
            ELSE ! IF(FAXIS==JAXIS) THEN
               DEL_EP = DXX(1) - ABS(XB_IB)
               IF( DEL_EP < THRES_FCT_EP*DXX(1) ) THEN
                  DEL_EP = DEL_EP + DXX(1);
                  IRC=II+I_SGN; JRC=JJ; KRC=KK
                  IRCEDG = ECVAR(IRC,JRC,KRC,IBM_IDCE,IEC)
                  IF (IRCEDG>0) THEN
                     CEP = (DXX(1) - ABS(XB_IB))/DEL_EP; CB=DXX(1)/DEL_EP
                     IBM_RCEDGE(IRCEDG)%DUIDXJ((/ -ICD, ICD /))    = 0.5_EB*(IBM_RCEDGE(IRCEDG)%DUIDXJ(ICD_SGN) + &
                                                                     CEP*   DUIDXJ_EP(ICD_SGN) + CB*   DUIDXJ(ICD_SGN))
                     IBM_RCEDGE(IRCEDG)%MU_DUIDXJ((/ -ICD, ICD /)) = 0.5_EB*(IBM_RCEDGE(IRCEDG)%MU_DUIDXJ(ICD_SGN) + &
                                                                     CEP*MU_DUIDXJ_EP(ICD_SGN) + CB*MU_DUIDXJ(ICD_SGN))
                  ENDIF
               ENDIF
            ENDIF
      END SELECT IEC_SELECT_2

   ENDDO SIGN_LOOP
ENDDO ORIENTATION_LOOP

! Loop over all 4 normal directions and compute vorticity and stress tensor components for each

SIGN_LOOP_2: DO I_SGN=-1,1,2
   ORIENTATION_LOOP_2: DO ICD=1,2
      IF (ICD==1) THEN
         ICDO=2
      ELSE ! ICD=2
         ICDO=1
      ENDIF
      ICD_SGN = I_SGN*ICD
      IF (ALTERED_GRADIENT(ICD_SGN)) THEN ! Note, altered gradients are extrapolated to IB edge using boundary B and external EP.
            DUIDXJ_USE(ICD) =    EC_B(ICD_SGN)*DUIDXJ(ICD_SGN)  +    EC_EP(ICD_SGN)*DUIDXJ_EP(ICD_SGN)
         MU_DUIDXJ_USE(ICD) = EC_B(ICD_SGN)*MU_DUIDXJ(ICD_SGN)  + EC_EP(ICD_SGN)*MU_DUIDXJ_EP(ICD_SGN)
      ELSEIF (ALTERED_GRADIENT(-ICD_SGN)) THEN
            DUIDXJ_USE(ICD) =    EC_B(-ICD_SGN)*DUIDXJ(-ICD_SGN) +    EC_EP(-ICD_SGN)*DUIDXJ_EP(-ICD_SGN)
         MU_DUIDXJ_USE(ICD) = EC_B(-ICD_SGN)*MU_DUIDXJ(-ICD_SGN) + EC_EP(-ICD_SGN)*MU_DUIDXJ_EP(-ICD_SGN)
      ELSE
         CYCLE ORIENTATION_LOOP_2
      ENDIF
      ICDO_SGN = I_SGN*ICDO
      IF (ALTERED_GRADIENT(ICDO_SGN)) THEN
            DUIDXJ_USE(ICDO) =     EC_B(ICDO_SGN)*DUIDXJ(ICDO_SGN) +    EC_EP(ICDO_SGN)*DUIDXJ_EP(ICDO_SGN)
         MU_DUIDXJ_USE(ICDO) =  EC_B(ICDO_SGN)*MU_DUIDXJ(ICDO_SGN) + EC_EP(ICDO_SGN)*MU_DUIDXJ_EP(ICDO_SGN)
      ELSEIF (ALTERED_GRADIENT(-ICDO_SGN)) THEN
            DUIDXJ_USE(ICDO) =   EC_B(-ICDO_SGN)*DUIDXJ(-ICDO_SGN) +    EC_EP(-ICDO_SGN)*DUIDXJ_EP(-ICDO_SGN)
         MU_DUIDXJ_USE(ICDO) =EC_B(-ICDO_SGN)*MU_DUIDXJ(-ICDO_SGN) + EC_EP(-ICDO_SGN)*MU_DUIDXJ_EP(-ICDO_SGN)
      ELSE
            DUIDXJ_USE(ICDO) = 0._EB
         MU_DUIDXJ_USE(ICDO) = 0._EB
      ENDIF
      OME_E(ICD_SGN,IE) =    DUIDXJ_USE(1) -    DUIDXJ_USE(2)
      TAU_E(ICD_SGN,IE) = MU_DUIDXJ_USE(1) + MU_DUIDXJ_USE(2)
   ENDDO ORIENTATION_LOOP_2
ENDDO SIGN_LOOP_2

! !IF(NM==2 .AND. II==8 .AND. JJ==9 .AND. KK==10 .AND. IEC==KAXIS) THEN
! IF(NM==1 .AND. II==0 .AND. JJ==6 .AND. KK==2 .AND. IEC==JAXIS) THEN
! IF(NM==2 .AND. II==8 .AND. JJ==9 .AND. KK==8 .AND. IEC==JAXIS) THEN
! IF(NM==1 .AND. IEC==JAXIS .AND. II==41 .AND. JJ==20 .AND. KK==32) THEN
!    WRITE(LU_ERR,*) ' '
!    WRITE(LU_ERR,*) 'IBEDGE      =',IEDGE,PREDICTOR,II,JJ,KK
!    WRITE(LU_ERR,*) 'IBEDGE OME_EP=',OMEV_EP((/-2,-1,1,2/)) !,OME_B
!    WRITE(LU_ERR,*) 'IBEDGE TAU_EP=',TAUV_EP((/-2,-1,1,2/)) !,TAU_B,MU_DUDXN
!    WRITE(LU_ERR,*) 'IBEDGE OME_E=',OME_E((/-2,-1,1,2/),IBM_EDGE%IE) !,OME_B
!    WRITE(LU_ERR,*) 'IBEDGE TAU_E=',TAU_E((/-2,-1,1,2/),IBM_EDGE%IE) !,TAU_B,MU_DUDXN
!    WRITE(LU_ERR,*) 'IBEDGE VLGAS=',VLG((/-2,-1,1,2/))
!    WRITE(LU_ERR,*) 'IBEDGE NU   =',NUV((/-2,-1,1,2/))
!    WRITE(LU_ERR,*) 'IBEDGE RGH  =',RGH((/-2,-1,1,2/))
!    WRITE(LU_ERR,*) 'IBEDGE UTAU =',UTA((/-2,-1,1,2/))
!    WRITE(LU_ERR,*) 'IBEDGE EC_B =',EC_B((/-2,-1,1,2/))
!    WRITE(LU_ERR,*) 'IBEDGE EC_EP=',EC_EP((/-2,-1,1,2/))
! ENDIF

RETURN
END SUBROUTINE IBM_EDGE_TAU_OMG

! SUBROUTINE GET_QUAD_VEL(DF,DE,UF,UE,UB,USTR_2)
!
! REAL(EB), INTENT(IN) :: DF,DE,UF,UE,UB
! REAL(EB), INTENT(OUT):: USTR_2
! ! Local variables:
! REAL(EB) :: B_POLY, C_POLY
!
! B_POLY = -(2._EB*(DE**2*UB + 2._EB*DF**2*UB - DE**2*UF + DF**2*UE - 3._EB*DF**2*UF + &
!                   3._EB*DE*DF*UB - 3._EB*DE*DF*UF))/(DF*(DE + DF)**2 + TWO_EPSILON_EB)
! C_POLY =  (3._EB*(DE*UB + DF*UB - DE*UF + DF*UE - 2._EB*DF*UF))/(DF*(DE + DF)**2 + TWO_EPSILON_EB)
! USTR_2  =  UB + B_POLY*DXN_STRM_UB/2._EB + C_POLY*(DXN_STRM_UB/2._EB)**2
!
! RETURN
! END SUBROUTINE GET_QUAD_VEL

END SUBROUTINE CCIBM_VELOCITY_BC

! ! ------------------------- CCIBM_RESCALE_FACE_FORCE ---------------------------
!
! SUBROUTINE CCIBM_RESCALE_FACE_FORCE(NM)
!
! INTEGER, INTENT(IN) :: NM
!
! ! Local Vars:
! INTEGER :: ICF,I,J,K,X1AXIS
! !REAL(EB):: AREA_CF
!
! CUTFACE_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
!
!    IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE
!    ! IW = CUT_FACE(ICF)%IWC
!    ! IF ( (IW > 0) .AND. (WALL(IW)%BOUNDARY_TYPE==SOLID_BOUNDARY   .OR. &
!    !                      WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY    .OR. &
!    !                      WALL(IW)%BOUNDARY_TYPE==MIRROR_BOUNDARY) ) CYCLE ! Here force Open boundaries.
!
!    I      = CUT_FACE(ICF)%IJK(IAXIS)
!    J      = CUT_FACE(ICF)%IJK(JAXIS)
!    K      = CUT_FACE(ICF)%IJK(KAXIS)
!    X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
!    ! AREA_CF   = SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))
!
!    SELECT CASE(X1AXIS)
!    CASE(IAXIS); FVX(I,J,K) = FVX(I,J,K)*CUT_FACE(ICF)%VOLFCT_CRF !AREA_CF/(DY(J)*DZ(K))
!    CASE(JAXIS); FVY(I,J,K) = FVY(I,J,K)*CUT_FACE(ICF)%VOLFCT_CRF !AREA_CF/(DX(I)*DZ(K))
!    CASE(KAXIS); FVZ(I,J,K) = FVZ(I,J,K)*CUT_FACE(ICF)%VOLFCT_CRF !AREA_CF/(DX(I)*DY(J))
!    END SELECT
!
! ENDDO CUTFACE_LOOP
!
!
! RETURN
! END SUBROUTINE CCIBM_RESCALE_FACE_FORCE


! --------------------------- CCIBM_VELOCITY_FLUX ------------------------------

SUBROUTINE CCIBM_VELOCITY_FLUX()

! We leave is as stub for now. Might use it in unstructured momentum calculation.

! Local Variables:
REAL(EB) :: TNOW
REAL(EB) :: TNOW2

IF ( FREEZE_VELOCITY .OR. SOLID_PHASE_ONLY ) RETURN
IF (PERIODIC_TEST == 103 .OR. PERIODIC_TEST == 11 .OR. PERIODIC_TEST==7) RETURN

TNOW = CURRENT_TIME()
T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(CCIBM_VELOCITY_FLUX_TIME_INDEX) = T_CC_USED(CCIBM_VELOCITY_FLUX_TIME_INDEX) + CURRENT_TIME() - TNOW2
RETURN
END SUBROUTINE CCIBM_VELOCITY_FLUX


! ---------------------------- CCIBM_TARGET_VELOC(NM) ------------------------------

SUBROUTINE CCIBM_TARGET_VELOCITY(DT,NM)
USE IEEE_ARITHMETIC, ONLY : IEEE_IS_NAN
USE TURBULENCE, ONLY : WALL_MODEL
USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN) :: DT

! Local Vars:
INTEGER :: I,J,K,ICF,IFACE,X1AXIS,NFACE,IW,EP,INPE,INT_NPE_LO,INT_NPE_HI,VIND
REAL(EB), ALLOCATABLE, DIMENSION(:,:,:) :: UVW_EP
INTEGER :: ICC,JCC,ICF1,ICF2,ICFA,ISIDE
REAL(EB) :: U_VELO(MAX_DIM),U_SURF(MAX_DIM),U_RELA(MAX_DIM),&
            NN(MAX_DIM),SS(MAX_DIM),TT(MAX_DIM),VELN,&
            X1F,IDX,CCM1,CCP1,TMPV(-1:0),RHOV(-1:0),MUV(-1:0),DIVV(-1:0),NU,MU_FACE,RHO_FACE,PRFCT=1._EB,&
            ZZ_GET(1:N_TRACKED_SPECIES),DXN_STRM_EP,DXN_STRM_FP,SLIP_FACTOR,SRGH,U_TAU,Y_PLUS,&
            U_IBM,V_IBM,W_IBM,&
            VAL_EP,DUMEB,COEF,TNOW,&
            U_NORM_EP,U_ORTH_EP,U_STRM_EP,U_NORM_FP,U_STRM_FP,DUSDN_FP

IF (SOLID_PHASE_ONLY .OR. FREEZE_VELOCITY) RETURN

TNOW = CURRENT_TIME()
IF (PREDICTOR) PRFCT = 0._EB
DUMEB= DT

! For mesh NM loop through CUT_FACE field and interpolate value of Un+1 approx
! to centroids:
CUTFACE_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH

   IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE
   IW = CUT_FACE(ICF)%IWC
   IF ( (IW > 0) .AND. (WALL(IW)%BOUNDARY_TYPE==SOLID_BOUNDARY   .OR. &
                        WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY    .OR. &
                        WALL(IW)%BOUNDARY_TYPE==MIRROR_BOUNDARY) ) CYCLE ! Here force Open boundaries.

   I      = CUT_FACE(ICF)%IJK(IAXIS)
   J      = CUT_FACE(ICF)%IJK(JAXIS)
   K      = CUT_FACE(ICF)%IJK(KAXIS)
   X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

   NFACE  = CUT_FACE(ICF)%NFACE

   IF(CC_ZEROIBM_VELO) THEN
      ! Velocity set to zero:
      CUT_FACE(ICF)%VELINT(1:NFACE) = 0._EB
   ELSE
      ALLOCATE(UVW_EP(IAXIS:KAXIS,0:INT_N_EXT_PTS,0:NFACE)); UVW_EP = 0._EB
      ! Interpolate Un+1 approx to External Points:
      IFACE_LOOP : DO IFACE=1,NFACE

         EXTERNAL_POINTS_LOOP : DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
            DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
               INT_NPE_LO = CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
               INT_NPE_HI = CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
               DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                  ! Value of velocity component VIND, for stencil point INPE of external normal point EP.
                  ! Case PREDICTOR => Un+1_aprx = Un
                  IF (PREDICTOR) VAL_EP = CUT_FACE(ICF)%INT_FVARS(INT_VEL_IND,INPE)
                  ! Case CORRECTOR => Un+1_aprx = Us
                  IF (CORRECTOR) VAL_EP = CUT_FACE(ICF)%INT_FVARS(INT_VELS_IND,INPE)
                  ! Interpolation coefficient from INPE to EP.
                  COEF = CUT_FACE(ICF)%INT_COEF(INPE)
                  ! Add to Velocity component VIND of EP:
                  UVW_EP(VIND,EP,IFACE) = UVW_EP(VIND,EP,IFACE) + COEF*VAL_EP
               ENDDO
            ENDDO
            IF (TWO_D) UVW_EP(JAXIS,EP,IFACE) = 0._EB
         ENDDO EXTERNAL_POINTS_LOOP
         INT_N_EXT_PTS_IF: IF(INT_N_EXT_PTS==1) THEN
            ! Transform External point velocities into local coordinate system, defined by the velocity vector in
            ! the first external point, and the surface:
            EP = 1
            U_VELO(IAXIS:KAXIS) = UVW_EP(IAXIS:KAXIS,EP,IFACE)
            VELN = 0._EB
            SRGH = 0._EB
            IF( CUT_FACE(ICF)%INT_INBFC(1,IFACE)== IBM_FTYPE_CFINB) THEN
               ICF1 = CUT_FACE(ICF)%INT_INBFC(2,IFACE)
               ICF2 = CUT_FACE(ICF)%INT_INBFC(3,IFACE)
               ICFA = CUT_FACE(ICF1)%CFACE_INDEX(ICF2)
               IF (ICFA>0) THEN
                  VELN = -CFACE(ICFA)%ONE_D%U_NORMAL
                  SRGH = SURFACE(CFACE(ICFA)%SURF_INDEX)%ROUGHNESS
               ENDIF
            ENDIF
            NN(IAXIS:KAXIS) = CUT_FACE(ICF)%INT_NOUT(IAXIS:KAXIS,IFACE)
            TT=0._EB
            SS=0._EB
            U_NORM_EP=0._EB
            U_ORTH_EP=0._EB
            U_STRM_EP=0._EB
            U_NORM_FP=0._EB
            U_STRM_FP=0._EB
            NN_IF: IF (NORM2(NN) > TWO_EPSILON_EB) THEN
               U_SURF(IAXIS:KAXIS) = VELN*NN
               U_RELA(IAXIS:KAXIS) = U_VELO(IAXIS:KAXIS)-U_SURF(IAXIS:KAXIS)
               ! Gives local velocity components U_STRM , U_ORTH , U_NORM
               ! in terms of unit vectors SS,TT,NN:
               CALL GET_LOCAL_VELOCITY(U_RELA,NN,TT,SS,U_NORM_EP,U_ORTH_EP,U_STRM_EP)
               ! U_STRM    = U_RELA(X1AXIS)
               ! SS(X1AXIS)= 1._EB ! Make stream the X1AXIS dir.

               ! Apply wall model to define streamwise velocity at interpolation point:
               DXN_STRM_EP =CUT_FACE(ICF)%INT_XN(EP,IFACE)! EP Position from Boundary in NOUT direction
               DXN_STRM_FP =CUT_FACE(ICF)%INT_XN(0,IFACE) ! Interp point position from Boundary in NOUT dir.
                                                        ! Note if this is a -ve number (i.e. Cartesian Faces),
                                                        ! Linear velocity variation should be used be used.

               DXN_STRMFP_IF: IF(CC_SLIPIBM_VELO) THEN
                  ! Slip condition: Make FP velocities equal to EP values.
                  U_STRM_FP = U_STRM_EP
                  U_NORM_FP = U_NORM_EP
               ELSEIF(DXN_STRM_FP < 0._EB) THEN
                  ! Linear variation:
                  U_STRM_FP = DXN_STRM_FP/DXN_STRM_EP*U_STRM_EP
                  U_NORM_FP = DXN_STRM_FP/DXN_STRM_EP*U_NORM_EP ! Assume rel U_normal decreases linearly.
               ELSE DXN_STRMFP_IF
                  ! Wall function:
                  X1F= MESHES(NM)%CUT_FACE(ICF)%XYZCEN(X1AXIS,IFACE)
                  IDX= 1._EB/ ( MESHES(NM)%CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE) - &
                                MESHES(NM)%CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE) )
                  CCM1= IDX*(MESHES(NM)%CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE)-X1F)
                  CCP1= IDX*(X1F-MESHES(NM)%CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE))
                  ! For NU use interpolation of values on neighboring cut-cells:
                  TMPV(-1:0) = -1._EB; RHOV(-1:0) = 0._EB; DIVV(-1:0) = 0._EB
                  DO ISIDE=-1,0
                     ZZ_GET = 0._EB
                     SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
                     CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                        ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
                        JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
                        TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
                        ZZ_GET(1:N_TRACKED_SPECIES) =  &
                               PRFCT *CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC) + &
                        (1._EB-PRFCT)*CUT_CELL(ICC)%ZZS(1:N_TRACKED_SPECIES,JCC)
                        RHOV(ISIDE) = PRFCT *CUT_CELL(ICC)%RHO(JCC) + &
                               (1._EB-PRFCT)*CUT_CELL(ICC)%RHOS(JCC)
                     END SELECT
                     CALL GET_VISCOSITY(ZZ_GET,MUV(ISIDE),TMPV(ISIDE))
                  ENDDO
                  MU_FACE = CCM1* MUV(-1) + CCP1* MUV(0)
                  RHO_FACE= CCM1*RHOV(-1) + CCP1*RHOV(0)
                  NU      = MU_FACE/RHO_FACE
                  CALL WALL_MODEL(SLIP_FACTOR,U_TAU,Y_PLUS,NU,SRGH,DXN_STRM_EP,U_STRM_EP,DXN_STRM_FP,U_STRM_FP,DUSDN_FP)
               ENDIF DXN_STRMFP_IF
            ENDIF NN_IF

            ! Velocity U_ORTH is zero by construction.
            CUT_FACE(ICF)%VELINT(IFACE) = U_NORM_FP*NN(X1AXIS) + U_STRM_FP*SS(X1AXIS) + U_SURF(X1AXIS)
            IF (DEBUG_IBM_INTERPOLATION) THEN
               IF (IEEE_IS_NAN(CUT_FACE(ICF)%VELINT(IFACE))) THEN
                  WRITE(LU_ERR,*) 'VELINT CUTFACE IN FLUX2=',CUT_FACE(ICF)%IJK(IAXIS:KAXIS),ICF,IFACE,X1AXIS
                  WRITE(LU_ERR,*) 'UNORM,NN(X1AXIS),U_STRM2,SS(X1AXIS)=',U_NORM_FP,NN(X1AXIS),U_STRM_FP,SS(X1AXIS)
                  CALL DEBUG_WAIT
               ENDIF
            ENDIF
         ENDIF INT_N_EXT_PTS_IF

      ENDDO IFACE_LOOP
      DEALLOCATE(UVW_EP)
   ENDIF

   ! Project Un+1 approx to cut-face centroids in X1AXIS direction:
   SELECT CASE(X1AXIS)
   CASE(IAXIS)

      ! Flux average velocities to Cartesian face center:
      ! This assumes zero velocity of solid part of Cartesian Face - !!
      U_IBM = 0._EB
      DO IFACE=1,NFACE
         U_IBM = U_IBM + CUT_FACE(ICF)%AREA(IFACE)* &
                         CUT_FACE(ICF)%VELINT(IFACE)
      ENDDO
      U_IBM = U_IBM/(DY(J)*DZ(K))
      CUT_FACE(ICF)%VELINT_CRF = U_IBM ! Store U_IBM for forcing in CCIBM_NO_FLUX

   CASE(JAXIS)

      ! Flux average velocities to Cartesian face center:
      ! This assumes zero velocity of solid part of Cartesian Face - !!
      V_IBM = 0._EB
      DO IFACE=1,NFACE
         V_IBM = V_IBM + CUT_FACE(ICF)%AREA(IFACE)*&
                         CUT_FACE(ICF)%VELINT(IFACE)
      ENDDO
      V_IBM = V_IBM/(DX(I)*DZ(K))
      CUT_FACE(ICF)%VELINT_CRF = V_IBM ! Store V_IBM for forcing in CCIBM_NO_FLUX

   CASE(KAXIS)

      ! Flux average velocities to Cartesian face center:
      ! This assumes zero velocity of solid part of Cartesian Face - !!
      W_IBM = 0._EB
      DO IFACE=1,NFACE
         W_IBM = W_IBM + CUT_FACE(ICF)%AREA(IFACE)*&
                         CUT_FACE(ICF)%VELINT(IFACE)
      ENDDO
      W_IBM = W_IBM/(DX(I)*DY(J))
      CUT_FACE(ICF)%VELINT_CRF = W_IBM ! Store W_IBM for forcing in CCIBM_NO_FLUX

   END SELECT

ENDDO CUTFACE_LOOP

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(CCIBM_TARGET_VELOCITY_TIME_INDEX) = T_CC_USED(CCIBM_TARGET_VELOCITY_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE CCIBM_TARGET_VELOCITY

! ! ---------------------------- DEBUG_WAIT ---------------------------------------
!
! #if defined(DEBUG_IBM_INTERPOLATION)
! SUBROUTINE DEBUG_WAIT
! USE COMP_FUNCTIONS, ONLY: FDS_SLEEP
! INTEGER I
! INTEGER, PARAMETER :: N_SEG=20
! WRITE(LU_ERR,'(A,I6,A,I2,A)') 'Process ID=',MY_RANK,'; execution halted for ',N_SEG,' seconds : '
! DO I=1,N_SEG
!    CALL FDS_SLEEP(1)
!    IF (I<N_SEG) THEN
!       WRITE(LU_ERR,'(I2,A)',ADVANCE="no") I,', '
!    ELSE
!       WRITE(LU_ERR,'(I2,A)') I,'.'
!    ENDIF
! ENDDO
! RETURN
! END SUBROUTINE DEBUG_WAIT
! #endif /* defined(DEBUG_IBM_INTERPOLATION) */

! ---------------------------- GET_LOCAL_VELOCITY ------------------------------

SUBROUTINE GET_LOCAL_VELOCITY(U_RELA,NN,TT,SS,U_NORM,U_ORTH,U_STRM)
USE MATH_FUNCTIONS, ONLY: CROSS_PRODUCT

REAL(EB), INTENT(IN) :: NN(IAXIS:KAXIS), U_RELA(IAXIS:KAXIS)
REAL(EB), INTENT(OUT):: TT(IAXIS:KAXIS), SS(IAXIS:KAXIS), U_NORM, U_ORTH, U_STRM

! Local Variables:
REAL(EB), DIMENSION(3), PARAMETER :: E1=(/1._EB,0._EB,0._EB/),E2=(/0._EB,1._EB,0._EB/),E3=(/0._EB,0._EB,1._EB/)
REAL(EB), DIMENSION(3,3) :: C

! find a vector TT in the tangent plane of the surface and orthogonal to U_VELO-U_SURF
CALL CROSS_PRODUCT(TT,NN,U_RELA) ! TT = NN x U_RELA
IF (ABS(NORM2(TT))<=TWO_EPSILON_EB) THEN
   ! tangent vector is completely arbitrary, just perpendicular to NN
   IF (ABS(NN(1))>=TWO_EPSILON_EB .OR.  ABS(NN(2))>=TWO_EPSILON_EB) TT = (/NN(2),-NN(1),0._EB/)
   IF (ABS(NN(1))<=TWO_EPSILON_EB .AND. ABS(NN(2))<=TWO_EPSILON_EB) TT = (/NN(3),0._EB,-NN(1)/)
ENDIF
TT = TT/NORM2(TT) ! normalize to unit vector
CALL CROSS_PRODUCT(SS,TT,NN) ! define the streamwise unit vector SS

! directional cosines (see Pope, Eq. A.11)
C(1,1) = DOT_PRODUCT(E1,SS)
C(1,2) = DOT_PRODUCT(E1,TT)
C(1,3) = DOT_PRODUCT(E1,NN)
C(2,1) = DOT_PRODUCT(E2,SS)
C(2,2) = DOT_PRODUCT(E2,TT)
C(2,3) = DOT_PRODUCT(E2,NN)
C(3,1) = DOT_PRODUCT(E3,SS)
C(3,2) = DOT_PRODUCT(E3,TT)
C(3,3) = DOT_PRODUCT(E3,NN)

! transform velocity (see Pope, Eq. A.17)
U_STRM = C(1,1)*U_RELA(1) + C(2,1)*U_RELA(2) + C(3,1)*U_RELA(3)
U_ORTH = C(1,2)*U_RELA(1) + C(2,2)*U_RELA(2) + C(3,2)*U_RELA(3)
U_NORM = C(1,3)*U_RELA(1) + C(2,3)*U_RELA(2) + C(3,3)*U_RELA(3)

RETURN
END SUBROUTINE GET_LOCAL_VELOCITY


! ------------------------------- CCIBM_NO_FLUX ---------------------------------

SUBROUTINE CCIBM_NO_FLUX(DT,NM,FORCE_FLG)

! Force to zero velocities on faces of type IBM_SOLID.

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN):: DT
LOGICAL, INTENT(IN) :: FORCE_FLG

! Local Variables:
REAL(EB), POINTER, DIMENSION(:,:,:) :: HP
REAL(EB):: U_IBM,V_IBM,W_IBM,DUUDT,DVVDT,DWWDT,RFODT,TNOW
INTEGER :: I,J,K,II,JJ,KK,IOR,IW,ICF,X1AXIS
TYPE(WALL_TYPE), POINTER :: WC
TYPE(EXTERNAL_WALL_TYPE), POINTER :: EWC

REAL(EB), PARAMETER :: A_THRESH_FORCING = 0.001_EB

! This is the CCIBM forcing routine for momentum eqns.

IF (SOLID_PHASE_ONLY .OR. FREEZE_VELOCITY) RETURN
IF ( PERIODIC_TEST == 103 .OR. PERIODIC_TEST == 11 .OR. PERIODIC_TEST==7) RETURN

TNOW=CURRENT_TIME()

RFODT = RELAXATION_FACTOR/DT

CALL POINT_TO_MESH(NM)

IF (PREDICTOR) HP => H
IF (CORRECTOR) HP => HS

FORCE_IF : IF (FORCE_FLG) THEN

! Force U velocities in IBM_SOLID faces to zero
U_IBM = 0._EB ! Body doesn't move.
DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID ) CYCLE
         IF (PREDICTOR) DUUDT = (U_IBM-U(I,J,K))*RFODT
         IF (CORRECTOR) DUUDT = (2._EB*U_IBM-(U(I,J,K)+US(I,J,K)))*RFODT
         FVX(I,J,K) = -RDXN(I)*(HP(I+1,J,K)-HP(I,J,K)) - DUUDT
         IF (.NOT. PRES_ON_WHOLE_DOMAIN) FVX(I,J,K) = - DUUDT ! This is because dH/dx = 0 in unstructured cases
                                                              ! and solid Cartesian faces.
      ENDDO
   ENDDO
ENDDO

! Force V velocities in IBM_SOLID faces to zero
V_IBM = 0._EB ! Body doesn't move.
DO K=1,KBAR
   DO J=0,JBAR
      DO I=1,IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,JAXIS) /= IBM_SOLID ) CYCLE
         IF (PREDICTOR) DVVDT = (V_IBM-V(I,J,K))*RFODT
         IF (CORRECTOR) DVVDT = (2._EB*V_IBM-(V(I,J,K)+VS(I,J,K)))*RFODT
         FVY(I,J,K) = -RDYN(J)*(HP(I,J+1,K)-HP(I,J,K)) - DVVDT
         IF (.NOT. PRES_ON_WHOLE_DOMAIN) FVY(I,J,K) = - DVVDT ! This is because dH/dx = 0 in unstructured cases
                                                              ! and solid Cartesian faces.
      ENDDO
   ENDDO
ENDDO

! Force W velocities in IBM_SOLID faces to zero
W_IBM = 0._EB ! Body doesn't move.
DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_SOLID ) CYCLE
         IF (PREDICTOR) DWWDT = (W_IBM-W(I,J,K))*RFODT
         IF (CORRECTOR) DWWDT = (2._EB*W_IBM-(W(I,J,K)+WS(I,J,K)))*RFODT
         FVZ(I,J,K) = -RDZN(K)*(HP(I,J,K+1)-HP(I,J,K)) - DWWDT
         IF (.NOT. PRES_ON_WHOLE_DOMAIN) FVZ(I,J,K) = - DWWDT ! This is because dH/dx = 0 in unstructured cases
                                                              ! and solid Cartesian faces.
      ENDDO
   ENDDO
ENDDO

! Force velocity components in cut cell faces
FORCE_GAS_FACE_IF: IF (FORCE_GAS_FACE .AND. .NOT.CC_STRESS_METHOD) THEN
   CUTFACE_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH

      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE CUTFACE_LOOP
      IW = CUT_FACE(ICF)%IWC
      IF ( (IW > 0) .AND. (WALL(IW)%BOUNDARY_TYPE==SOLID_BOUNDARY   .OR. &
                           WALL(IW)%BOUNDARY_TYPE==NULL_BOUNDARY    .OR. &
                           WALL(IW)%BOUNDARY_TYPE==MIRROR_BOUNDARY) ) CYCLE CUTFACE_LOOP ! Here force Open boundaries.

      I      = CUT_FACE(ICF)%IJK(IAXIS)
      J      = CUT_FACE(ICF)%IJK(JAXIS)
      K      = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      SELECT CASE(X1AXIS)
            CASE(IAXIS)
               U_IBM = CUT_FACE(ICF)%VELINT_CRF
               IF (PREDICTOR) DUUDT = (U_IBM-U(I,J,K))/DT
               IF (CORRECTOR) DUUDT = (2._EB*U_IBM-(U(I,J,K)+US(I,J,K)))/DT
               FVX(I,J,K) = -RDXN(I)*(HP(I+1,J,K)-HP(I,J,K)) - DUUDT

            CASE(JAXIS)
               V_IBM = CUT_FACE(ICF)%VELINT_CRF
               IF (PREDICTOR) DVVDT = (V_IBM-V(I,J,K))/DT
               IF (CORRECTOR) DVVDT = (2._EB*V_IBM-(V(I,J,K)+VS(I,J,K)))/DT
               FVY(I,J,K) = -RDYN(J)*(HP(I,J+1,K)-HP(I,J,K)) - DVVDT

            CASE(KAXIS)
               W_IBM = CUT_FACE(ICF)%VELINT_CRF
               IF (PREDICTOR) DWWDT = (W_IBM-W(I,J,K))/DT
               IF (CORRECTOR) DWWDT = (2._EB*W_IBM-(W(I,J,K)+WS(I,J,K)))/DT
               FVZ(I,J,K) = -RDZN(K)*(HP(I,J,K+1)-HP(I,J,K)) - DWWDT

         END SELECT

   ENDDO CUTFACE_LOOP
ENDIF FORCE_GAS_FACE_IF

IF(CC_STRESS_METHOD) THEN
   U_IBM = 0._EB; V_IBM = 0._EB; W_IBM = 0._EB
   CUTFACE_LOOP_2 : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE CUTFACE_LOOP_2
      I      = CUT_FACE(ICF)%IJK(IAXIS)
      J      = CUT_FACE(ICF)%IJK(JAXIS)
      K      = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)
      SELECT CASE(X1AXIS)
            CASE(IAXIS)
               IF (SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))/(DY(J)*DZ(K)) > A_THRESH_FORCING) CYCLE CUTFACE_LOOP_2
               IF (PREDICTOR) DUUDT = (U_IBM-U(I,J,K))/DT
               IF (CORRECTOR) DUUDT = (2._EB*U_IBM-(U(I,J,K)+US(I,J,K)))/DT
               FVX(I,J,K) = -RDXN(I)*(HP(I+1,J,K)-HP(I,J,K)) - DUUDT
            CASE(JAXIS)
               IF (SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))/(DX(I)*DZ(K)) > A_THRESH_FORCING) CYCLE CUTFACE_LOOP_2
               IF (PREDICTOR) DVVDT = (V_IBM-V(I,J,K))/DT
               IF (CORRECTOR) DVVDT = (2._EB*V_IBM-(V(I,J,K)+VS(I,J,K)))/DT
               FVY(I,J,K) = -RDYN(J)*(HP(I,J+1,K)-HP(I,J,K)) - DVVDT
            CASE(KAXIS)
               IF (SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))/(DX(I)*DY(J)) > A_THRESH_FORCING) CYCLE CUTFACE_LOOP_2
               IF (PREDICTOR) DWWDT = (W_IBM-W(I,J,K))/DT
               IF (CORRECTOR) DWWDT = (2._EB*W_IBM-(W(I,J,K)+WS(I,J,K)))/DT
               FVZ(I,J,K) = -RDZN(K)*(HP(I,J,K+1)-HP(I,J,K)) - DWWDT
         END SELECT
   ENDDO CUTFACE_LOOP_2
ENDIF

ELSE FORCE_IF

! Now set WALL_WORK(IW) to zero in EXTERNAL WALL CELLS of type IBM_SOLID:
! This Follows what is being done for external boundaries inside OBSTS (NULL_BOUNDARY).
EWC_LOOP : DO IW=1,N_EXTERNAL_WALL_CELLS
   WC => WALL(IW)
   IF (.NOT.(WC%BOUNDARY_TYPE==NULL_BOUNDARY .OR. WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY)) CYCLE
   EWC=>EXTERNAL_WALL(IW)

   II  = WC%ONE_D%II
   JJ  = WC%ONE_D%JJ
   KK  = WC%ONE_D%KK
   IOR = WC%ONE_D%IOR

   SELECT CASE(IOR)
   CASE( IAXIS)
      IF(FCVAR(II  ,JJ,KK,IBM_FGSC,IAXIS)==IBM_SOLID) WALL_WORK1(IW) = 0._EB
   CASE(-IAXIS)
      IF(FCVAR(II-1,JJ,KK,IBM_FGSC,IAXIS)==IBM_SOLID) WALL_WORK1(IW) = 0._EB
   CASE( JAXIS)
      IF(FCVAR(II,JJ  ,KK,IBM_FGSC,JAXIS)==IBM_SOLID) WALL_WORK1(IW) = 0._EB
   CASE(-JAXIS)
      IF(FCVAR(II,JJ-1,KK,IBM_FGSC,JAXIS)==IBM_SOLID) WALL_WORK1(IW) = 0._EB
   CASE( KAXIS)
      IF(FCVAR(II,JJ,KK  ,IBM_FGSC,KAXIS)==IBM_SOLID) WALL_WORK1(IW) = 0._EB
   CASE(-KAXIS)
      IF(FCVAR(II,JJ,KK-1,IBM_FGSC,KAXIS)==IBM_SOLID) WALL_WORK1(IW) = 0._EB
   END SELECT

ENDDO EWC_LOOP

ENDIF FORCE_IF

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) T_CC_USED(CCIBM_NO_FLUX_TIME_INDEX) = T_CC_USED(CCIBM_NO_FLUX_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE CCIBM_NO_FLUX


! ------------------------- CCIBM_COMPUTE_VELOCITY_ERROR -------------------------

SUBROUTINE CCIBM_COMPUTE_VELOCITY_ERROR(DT,NM)

! Compute velocity error on faces of type IBM_SOLID.

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN) :: DT

! Local Variables:
INTEGER :: I,J,K
REAL(EB):: UN_NEW, UN_NEW_OTHER, VELOCITY_ERROR, TNOW

IF (SOLID_PHASE_ONLY) RETURN
IF (FREEZE_VELOCITY)  RETURN
IF (.NOT. PRES_ON_WHOLE_DOMAIN) RETURN ! No error in IBM_SOLID faces, solver used in Cartesian unstructured.

TNOW = CURRENT_TIME()

CALL POINT_TO_MESH(NM)

UN_NEW_OTHER = 0._EB ! Body doesn't move.

! Compute U velocity errors in internal IBM_SOLID faces:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,IAXIS) /= IBM_SOLID ) CYCLE
         IF (PREDICTOR) UN_NEW = U(I,J,K)   - DT*(FVX(I,J,K) + RDXN(I)  *(H(I+1,J,K)-H(I,J,K)))
         IF (CORRECTOR) UN_NEW = 0.5_EB*(U(I,J,K)+US(I,J,K)  - DT*(FVX(I,J,K) + RDXN(I)  *(HS(I+1,J,K)-HS(I,J,K))))
         VELOCITY_ERROR = UN_NEW - UN_NEW_OTHER
         IF (ABS(VELOCITY_ERROR)>VELOCITY_ERROR_MAX(NM)) THEN
            VELOCITY_ERROR_MAX_LOC(1,NM) = I
            VELOCITY_ERROR_MAX_LOC(2,NM) = J
            VELOCITY_ERROR_MAX_LOC(3,NM) = K
            VELOCITY_ERROR_MAX(NM)       = ABS(VELOCITY_ERROR)
         ENDIF
      ENDDO
   ENDDO
ENDDO

! Compute V velocity errors in internal IBM_SOLID faces:
DO K=1,KBAR
   DO J=0,JBAR
      DO I=1,IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,JAXIS) /= IBM_SOLID ) CYCLE
         IF (PREDICTOR) UN_NEW = V(I,J,K)   - DT*(FVY(I,J,K) + RDYN(J)  *(H(I,J+1,K)-H(I,J,K)))
         IF (CORRECTOR) UN_NEW = 0.5_EB*(V(I,J,K)+VS(I,J,K)  - DT*(FVY(I,J,K) + RDYN(J)  *(HS(I,J+1,K)-HS(I,J,K))))
         VELOCITY_ERROR = UN_NEW - UN_NEW_OTHER
         IF (ABS(VELOCITY_ERROR)>VELOCITY_ERROR_MAX(NM)) THEN
            VELOCITY_ERROR_MAX_LOC(1,NM) = I
            VELOCITY_ERROR_MAX_LOC(2,NM) = J
            VELOCITY_ERROR_MAX_LOC(3,NM) = K
            VELOCITY_ERROR_MAX(NM)       = ABS(VELOCITY_ERROR)
         ENDIF
      ENDDO
   ENDDO
ENDDO

! Compute W velocity errors in internal IBM_SOLID faces:
DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,KAXIS) /= IBM_SOLID ) CYCLE
         IF (PREDICTOR) UN_NEW = W(I,J,K)   - DT*(FVZ(I,J,K) + RDZN(K)  *(H(I,J,K+1)-H(I,J,K)))
         IF (CORRECTOR) UN_NEW = 0.5_EB*(W(I,J,K)+WS(I,J,K)  - DT*(FVZ(I,J,K) + RDZN(K)  *(HS(I,J,K+1)-HS(I,J,K))))
         VELOCITY_ERROR = UN_NEW - UN_NEW_OTHER
         IF (ABS(VELOCITY_ERROR)>VELOCITY_ERROR_MAX(NM)) THEN
            VELOCITY_ERROR_MAX_LOC(1,NM) = I
            VELOCITY_ERROR_MAX_LOC(2,NM) = J
            VELOCITY_ERROR_MAX_LOC(3,NM) = K
            VELOCITY_ERROR_MAX(NM)       = ABS(VELOCITY_ERROR)
         ENDIF
      ENDDO
   ENDDO
ENDDO

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
IF (TIME_CC_IBM) &
   T_CC_USED(CCIBM_COMPUTE_VELOCITY_ERROR_TIME_INDEX) = T_CC_USED(CCIBM_COMPUTE_VELOCITY_ERROR_TIME_INDEX) + CURRENT_TIME() - TNOW
RETURN
END SUBROUTINE CCIBM_COMPUTE_VELOCITY_ERROR

! ------------------------------- GET_BOUND_VEL ---------------------------------

SUBROUTINE GET_BOUND_VEL(X1AXIS,INBFC_CFCEN,XYZ_PP,VELX1)

INTEGER, INTENT(IN) :: X1AXIS,INBFC_CFCEN(1:3)
REAL(EB),INTENT(IN) :: XYZ_PP(IAXIS:KAXIS)
REAL(EB),INTENT(OUT):: VELX1

! Local Variables
REAL(EB) :: DUMMY
INTEGER  :: IND1,IND2,ICF

VELX1 = 0._EB
! This routine computes boundary velocity of a boundary point on INBFC_CFCEN(1:3) INBOUNDARY cut-face
! with coordinates XYZ_PP. Will make use of velocity field defined on GEOMETRY.

! For now Set to CFACEs U_NORMAL or U_NORMAL_S depending on predictor or corrector:
DUMMY = XYZ_PP(X1AXIS) ! Dummy to avoid compilation warning on currently unused point location within cut-face.

! Inboundary cut-face indexes:
! INBFC_CFCEN(1) is either a point inside the Cartesian cell IBM_FTYPE_CFINB, or a point in a Cartesian cell
! vertex IBM_FTYPE_SVERT:
IND1=INBFC_CFCEN(2)
IND2=INBFC_CFCEN(3)
IF(IND1<=0 .OR. IND2<=0) RETURN ! If boundary cut-face undefined, with VELX1 set to 0._EB.
IF(CUT_FACE(IND1)%STATUS/=IBM_INBOUNDARY) RETURN ! Return if face is not inboundary face.

ICF = CUT_FACE(IND1)%CFACE_INDEX(IND2)

IF (ICF <=0) RETURN ! This uses VELX1 = 0._EB when the inboundary cut-face used in the interpolation is located on
                    ! a ghost cell (no CFACEs are defined in ghost cells).

! Velocity into Gas Region, component along X1AXIS:
IF (PREDICTOR) THEN
   VELX1 = -CFACE(ICF)%ONE_D%U_NORMAL * CFACE(ICF)%NVEC(X1AXIS)
ELSE
   VELX1 = -CFACE(ICF)%ONE_D%U_NORMAL_S* CFACE(ICF)%NVEC(X1AXIS)
ENDIF

RETURN
END SUBROUTINE GET_BOUND_VEL


! -------------------------- CCIBM_CHECK_DIVERGENCE -----------------------------

SUBROUTINE CCIBM_CHECK_DIVERGENCE(T,DT,PREDVEL)

USE MPI_F08

! This routine is to be used at the end of predictor or corrector:
REAL(EB),INTENT(IN) :: T,DT
LOGICAL, INTENT(IN) :: PREDVEL

! Local Variables:
INTEGER :: NM, I, J, K, ICC, NCELL, JCC, IFC, IFACE, LOWHIGH, ILH, X1AXIS, IFC2, IFACE2, ICFA, IPZ

REAL(EB):: PRFCT, DIV, RES, AF, VELN, DIVVOL, VOL, FCT, DPCC, DIV2,TLOC,DTLOC

REAL(EB), POINTER, DIMENSION(:,:,:)  :: UP=>NULL(), VP=>NULL(), WP=>NULL(), DP=>NULL()
REAL(EB), ALLOCATABLE, DIMENSION(:)  :: RESMAXV, RESVOLMX
REAL(EB), ALLOCATABLE, DIMENSION(:,:):: DIVMNX, DIVVOLMNX, VOLMNX
INTEGER,  ALLOCATABLE, DIMENSION(:,:):: IJKRM, RESICJCMX
INTEGER,  ALLOCATABLE, DIMENSION(:,:,:):: IJKMNX    , DIVVOLIJKMNX    , DIVVOLICJCMNX     ,DIVICJCMNX
REAL(EB), ALLOCATABLE, DIMENSION(:,:,:):: XYZMNX
INTEGER :: NMV(1), IERR
REAL(EB), ALLOCATABLE, DIMENSION(:)  :: RESMAXV_AUX, RESVOLMX_AUX
REAL(EB), ALLOCATABLE, DIMENSION(:,:):: DIVMNX_AUX, DIVVOLMNX_AUX, VOLMNX_AUX
INTEGER,  ALLOCATABLE, DIMENSION(:,:):: IJKRM_AUX, RESICJCMX_AUX
INTEGER,  ALLOCATABLE, DIMENSION(:,:,:):: IJKMNX_AUX, DIVVOLIJKMNX_AUX, DIVVOLICJCMNX_AUX ,DIVICJCMNX_AUX
REAL(EB), ALLOCATABLE, DIMENSION(:,:,:):: XYZMNX_AUX
REAL(EB), POINTER, DIMENSION(:) :: D_PBAR_DT_P

! Allocate div Containers
ALLOCATE( RESMAXV(NMESHES), DIVMNX(LOW_IND:HIGH_IND,NMESHES), DIVVOLMNX(LOW_IND:HIGH_IND,NMESHES) )
ALLOCATE( IJKRM(MAX_DIM,NMESHES), IJKMNX(MAX_DIM,LOW_IND:HIGH_IND,NMESHES), XYZMNX(MAX_DIM,LOW_IND:HIGH_IND,NMESHES), &
          DIVVOLIJKMNX(MAX_DIM,LOW_IND:HIGH_IND,NMESHES),  DIVVOLICJCMNX(2,LOW_IND:HIGH_IND,1:NMESHES), &
          DIVICJCMNX(2,LOW_IND:HIGH_IND,1:NMESHES) ,  VOLMNX(LOW_IND:HIGH_IND,1:NMESHES) )
ALLOCATE( RESICJCMX(1:2,1:NMESHES), RESVOLMX(1:NMESHES) )

! Initialize div containers
RESMAXV(1:NMESHES) = 0._EB
DIVMNX(LOW_IND:HIGH_IND,1:NMESHES)    = 0._EB
DIVVOLMNX(LOW_IND:HIGH_IND,1:NMESHES) = 0._EB
IJKRM(IAXIS:KAXIS,1:NMESHES)                         = 0
IJKMNX(IAXIS:KAXIS,LOW_IND:HIGH_IND,1:NMESHES)       = 0
DIVVOLIJKMNX(IAXIS:KAXIS,LOW_IND:HIGH_IND,1:NMESHES) = 0
DIVVOLICJCMNX(1:2,LOW_IND:HIGH_IND,1:NMESHES)        = 0
DIVICJCMNX(1:2,LOW_IND:HIGH_IND,1:NMESHES)           = 0
RESICJCMX(1:2,1:NMESHES)                             = 0
VOLMNX(LOW_IND:HIGH_IND,1:NMESHES)                   = 0._EB
RESVOLMX(1:NMESHES)                                  = 0._EB
XYZMNX(IAXIS:KAXIS,LOW_IND:HIGH_IND,1:NMESHES)       = 0._EB
TLOC = T
DTLOC= DT
! Meshes Loop:
MESHES_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   DIVMNX(HIGH_IND,NM)     = -10000._EB
   DIVMNX(LOW_IND ,NM)     =  10000._EB
   DIVVOLMNX(HIGH_IND,NM)  = -10000._EB
   DIVVOLMNX(LOW_IND ,NM)  =  10000._EB

   CALL POINT_TO_MESH(NM)

   IF (EVACUATION_ONLY(NM)) CYCLE

   IF (PREDVEL) THEN ! Take divergence from predicted velocities
      UP => US
      VP => VS
      WP => WS
      DP => DS ! Thermodynamic divergence
      D_PBAR_DT_P => D_PBAR_DT_S
      PRFCT= 1._EB
   ELSE ! Take divergence from final velocities
      UP => U
      VP => V
      WP => W
      DP => D !DDT
      D_PBAR_DT_P => D_PBAR_DT
      PRFCT= 0._EB
   ENDIF

   ! First Regular GASPHASE cells:
   DO K=1,KBAR
      DO J=1,JBAR
         LOOP1: DO I=1,IBAR
            IF( CCVAR(I,J,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
            IF( SOLID(CELL_INDEX(I,J,K)) ) CYCLE
            ! 3D Cartesian divergence:
            DIV = (UP(I,J,K)-UP(I-1,J,K))*RDX(I) + &
                  (VP(I,J,K)-VP(I,J-1,K))*RDY(J) + &
                  (WP(I,J,K)-WP(I,J,K-1))*RDZ(K)
            RES = ABS(DIV-DP(I,J,K))
            IF (RES >= RESMAXV(NM)) THEN
               RESMAXV(NM) = RES
               IJKRM(IAXIS:KAXIS,NM)= (/ I,J,K /)
               RESVOLMX(NM) = DX(I)*DY(J)*DZ(K)
            ENDIF
            IF (DIV >= DIVMNX(HIGH_IND,NM)) THEN
               DIVMNX(HIGH_IND,NM) = DIV
               IJKMNX(IAXIS:KAXIS,HIGH_IND,NM) = (/ I,J,K /)
               XYZMNX(IAXIS:KAXIS,HIGH_IND,NM) = (/ XC(I),YC(J),ZC(K) /)
               VOLMNX(HIGH_IND,NM) = DX(I)*DY(J)*DZ(K)
            ENDIF
            IF (DIV < DIVMNX(LOW_IND ,NM)) THEN
               DIVMNX(LOW_IND ,NM) = DIV
               IJKMNX(IAXIS:KAXIS,LOW_IND ,NM) = (/ I,J,K /)
               XYZMNX(IAXIS:KAXIS,LOW_IND ,NM) = (/ XC(I),YC(J),ZC(K) /)
               VOLMNX(LOW_IND,NM) = DX(I)*DY(J)*DZ(K)
            ENDIF
            DIVVOL = DIV*DX(I)*DY(J)*DZ(K)
            IF (DIVVOL >= DIVVOLMNX(HIGH_IND,NM)) THEN
               DIVVOLMNX(HIGH_IND,NM) = DIVVOL
               DIVVOLIJKMNX(IAXIS:KAXIS,HIGH_IND,NM) = (/ I,J,K /)
            ENDIF
            IF (DIVVOL < DIVVOLMNX(LOW_IND ,NM)) THEN
               DIVVOLMNX(LOW_IND ,NM) = DIVVOL
               DIVVOLIJKMNX(IAXIS:KAXIS,LOW_IND ,NM) = (/ I,J,K /)
            ENDIF
         ENDDO LOOP1
      ENDDO
   ENDDO

   ! Then cut-cells:
   ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      NCELL  = CUT_CELL(ICC)%NCELL
      I      = CUT_CELL(ICC)%IJK(IAXIS)
      J      = CUT_CELL(ICC)%IJK(JAXIS)
      K      = CUT_CELL(ICC)%IJK(KAXIS)
      IF( SOLID(CELL_INDEX(I,J,K)) ) CYCLE
      IPZ = PRESSURE_ZONE(I,J,K)
      DIVVOL = 0._EB
      DPCC   = 0._EB
      VOL    = 0._EB
      JCC_LOOP : DO JCC=1,NCELL
         VOL  = VOL + CUT_CELL(ICC)%VOLUME(JCC)
         IFC_LOOP3 : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            AF     = 0._EB
            VELN   = 0._EB
            SELECT CASE(CUT_CELL(ICC)%FACE_LIST(1,IFACE))
            CASE(IBM_FTYPE_RGGAS) ! REGULAR GASPHASE
               LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
               X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)
               ILH     =        LOWHIGH - 1
               FCT     = REAL(2*LOWHIGH - 3, EB)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  AF   = DY(J)*DZ(K)
                  VELN = FCT*UP(I-1+ILH,J,K)
               CASE(JAXIS)
                  AF   = DX(I)*DZ(K)
                  VELN = FCT*VP(I,J-1+ILH,K)
               CASE(KAXIS)
                  AF   = DX(I)*DY(J)
                  VELN = FCT*WP(I,J,K-1+ILH)
               END SELECT
            CASE(IBM_FTYPE_CFGAS)
               LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
               FCT     = REAL(2*LOWHIGH - 3, EB)
               IFC2    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
               IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
               AF      = CUT_FACE(IFC2)%AREA(IFACE2)
               VELN    = FCT*((1._EB-PRFCT)*CUT_FACE(IFC2)%VEL( IFACE2) + &
                                     PRFCT *CUT_FACE(IFC2)%VELS(IFACE2))
            CASE(IBM_FTYPE_CFINB)
               FCT     = 1._EB ! Normal velocity defined into the body.
               IFC2    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
               IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
               ICFA    = CUT_FACE(IFC2)%CFACE_INDEX(IFACE2)
               AF      = CUT_FACE(IFC2)%AREA(IFACE2)
               VELN    = FCT*((1._EB-PRFCT)*(CUT_FACE(IFC2)%VEL( IFACE2)+CFACE(ICFA)%ONE_D%U_NORMAL) + &
                                     PRFCT *(CUT_FACE(IFC2)%VELS(IFACE2)+CFACE(ICFA)%ONE_D%U_NORMAL_S))
            END SELECT
            DIVVOL = DIVVOL + AF*VELN
         ENDDO IFC_LOOP3
         ! Thermodynamic divergence * vol:
         DPCC= DPCC + ( (1._EB-PRFCT)*CUT_CELL(ICC)%D(JCC) + PRFCT*CUT_CELL(ICC)%DS(JCC) ) * CUT_CELL(ICC)%VOLUME(JCC)
         ! Add Pressure derivative to divergence:
         IF (IPZ>0) &
         DPCC= DPCC - (R_PBAR(K,IPZ)-CUT_CELL(ICC)%RTRM(JCC))*D_PBAR_DT_P(IPZ) * CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO JCC_LOOP

      DIV = DIVVOL / (DX(I)*DY(J)*DZ(K))
      RES = ABS(DIVVOL-DPCC)/(DX(I)*DY(J)*DZ(K))
      DIV2 = (UP(I,J,K)-UP(I-1,J,K))*RDX(I) + &
             (VP(I,J,K)-VP(I,J-1,K))*RDY(J) + &
             (WP(I,J,K)-WP(I,J,K-1))*RDZ(K)
      IF (RES >= RESMAXV(NM)) THEN
         RESMAXV(NM) = RES
         IJKRM(IAXIS:KAXIS,NM)= (/ I,J,K /)
         RESICJCMX(1:2,NM) = (/ ICC, NCELL /)
         RESVOLMX(NM) = VOL !CUT_CELL(ICC)%VOLUME(JCC)
      ENDIF
      IF (DIV >= DIVMNX(HIGH_IND,NM)) THEN
         DIVMNX(HIGH_IND,NM) = DIV
         IJKMNX(IAXIS:KAXIS,HIGH_IND,NM) = (/ I,J,K /)
         XYZMNX(IAXIS:KAXIS,HIGH_IND,NM) = (/ XC(I),YC(J),ZC(K) /)
         DIVICJCMNX(1:2,HIGH_IND,NM) = (/ ICC, NCELL /)
         VOLMNX(HIGH_IND,NM) = VOL !CUT_CELL(ICC)%VOLUME(JCC)
      ENDIF
      IF (DIV < DIVMNX(LOW_IND ,NM)) THEN
         DIVMNX(LOW_IND ,NM) = DIV
         IJKMNX(IAXIS:KAXIS,LOW_IND ,NM) = (/ I,J,K /)
         XYZMNX(IAXIS:KAXIS,LOW_IND ,NM) = (/ XC(I),YC(J),ZC(K) /)
         DIVICJCMNX(1:2,LOW_IND,NM) = (/ ICC, NCELL /)
         VOLMNX(LOW_IND,NM) = VOL !CUT_CELL(ICC)%VOLUME(JCC)
      ENDIF
      IF (DIVVOL >= DIVVOLMNX(HIGH_IND,NM)) THEN
         DIVVOLMNX(HIGH_IND,NM) = DIVVOL
         DIVVOLIJKMNX(IAXIS:KAXIS,HIGH_IND,NM) = (/ I,J,K /)
         DIVVOLICJCMNX(1:2,HIGH_IND,NM) = (/ ICC, NCELL/)
      ENDIF
      IF (DIVVOL < DIVVOLMNX(LOW_IND ,NM)) THEN
         DIVVOLMNX(LOW_IND ,NM) = DIVVOL
         DIVVOLIJKMNX(IAXIS:KAXIS,LOW_IND ,NM) = (/ I,J,K /)
         DIVVOLICJCMNX(1:2,LOW_IND,NM) = (/ ICC, NCELL /)
      ENDIF
   ENDDO ICC_LOOP

   ! Assign max residual and divergence to corresponding location in MESHES(NM):
   RESMAX = RESMAXV(NM)
   IRM = IJKRM(IAXIS,NM)
   JRM = IJKRM(JAXIS,NM)
   KRM = IJKRM(KAXIS,NM)

   DIVMN = DIVMNX(LOW_IND ,NM)
   IMN = IJKMNX(IAXIS,LOW_IND ,NM)
   JMN = IJKMNX(JAXIS,LOW_IND ,NM)
   KMN = IJKMNX(KAXIS,LOW_IND ,NM)

   DIVMX = DIVMNX(HIGH_IND ,NM)
   IMX = IJKMNX(IAXIS,HIGH_IND ,NM)
   JMX = IJKMNX(JAXIS,HIGH_IND ,NM)
   KMX = IJKMNX(KAXIS,HIGH_IND ,NM)

ENDDO MESHES_LOOP

! Here All_Reduce SUM all mesh values to write if GET_CUTCELLS_VERBOSE:
DEBUG_CCREGION_SCALAR_TRANSPORT_IF : IF (DEBUG_CCREGION_SCALAR_TRANSPORT) THEN
   IF (GET_CUTCELLS_VERBOSE) THEN
      IF (N_MPI_PROCESSES>1) THEN
         ! Allocate aux div Containers
         ALLOCATE( RESMAXV_AUX(NMESHES), DIVMNX_AUX(LOW_IND:HIGH_IND,NMESHES), DIVVOLMNX_AUX(LOW_IND:HIGH_IND,NMESHES) )
         ALLOCATE( IJKRM_AUX(MAX_DIM,NMESHES), IJKMNX_AUX(MAX_DIM,LOW_IND:HIGH_IND,NMESHES), &
                   XYZMNX_AUX(MAX_DIM,LOW_IND:HIGH_IND,NMESHES),&
                   DIVVOLIJKMNX_AUX(MAX_DIM,LOW_IND:HIGH_IND,NMESHES),  DIVVOLICJCMNX_AUX(2,LOW_IND:HIGH_IND,1:NMESHES), &
                   DIVICJCMNX_AUX(2,LOW_IND:HIGH_IND,1:NMESHES) ,  VOLMNX_AUX(LOW_IND:HIGH_IND,1:NMESHES) )
         ALLOCATE( RESICJCMX_AUX(1:2,1:NMESHES), RESVOLMX_AUX(1:NMESHES) )
         RESMAXV_AUX(:)           = RESMAXV(:)
         DIVMNX_AUX(:,:)          = DIVMNX(:,:)
         DIVVOLMNX_AUX(:,:)       = DIVVOLMNX(:,:)
         IJKRM_AUX(:,:)           = IJKRM(:,:)
         IJKMNX_AUX(:,:,:)        = IJKMNX(:,:,:)
         XYZMNX_AUX(:,:,:)        = XYZMNX(:,:,:)
         DIVVOLIJKMNX_AUX(:,:,:)  = DIVVOLIJKMNX(:,:,:)
         DIVVOLICJCMNX_AUX(:,:,:) = DIVVOLICJCMNX(:,:,:)
         DIVICJCMNX_AUX(:,:,:)    = DIVICJCMNX(:,:,:)
         VOLMNX_AUX(:,:)          = VOLMNX(:,:)
         RESICJCMX_AUX(:,:)       = RESICJCMX(:,:)
         RESVOLMX_AUX(:)          = RESVOLMX(:)
         ! Reals:
         CALL MPI_ALLREDUCE(RESMAXV_AUX(1) , RESMAXV(1) ,   NMESHES, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(DIVMNX_AUX(1,1), DIVMNX(1,1), 2*NMESHES, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(DIVVOLMNX_AUX(1,1), DIVVOLMNX(1,1), 2*NMESHES, MPI_DOUBLE_PRECISION, MPI_SUM, &
                            MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(VOLMNX_AUX(1,1), VOLMNX(1,1), 2*NMESHES, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(RESVOLMX_AUX(1), RESVOLMX(1),   NMESHES, MPI_DOUBLE_PRECISION, MPI_SUM, MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(XYZMNX_AUX(1,1,1), XYZMNX(1,1,1), MAX_DIM*2*NMESHES, MPI_DOUBLE_PRECISION, MPI_SUM, &
                            MPI_COMM_WORLD, IERR)
         ! Integers:
         CALL MPI_ALLREDUCE(IJKRM_AUX(1,1), IJKRM(1,1), MAX_DIM*NMESHES, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(IJKMNX_AUX(1,1,1), IJKMNX(1,1,1), MAX_DIM*2*NMESHES, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(DIVVOLIJKMNX_AUX(1,1,1), DIVVOLIJKMNX(1,1,1), MAX_DIM*2*NMESHES, MPI_INTEGER, MPI_SUM, &
                            MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(DIVVOLICJCMNX_AUX(1,1,1), DIVVOLICJCMNX(1,1,1), 2*2*NMESHES, MPI_INTEGER, MPI_SUM, &
                            MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(DIVICJCMNX_AUX(1,1,1), DIVICJCMNX(1,1,1), 2*2*NMESHES, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, IERR)
         CALL MPI_ALLREDUCE(RESICJCMX_AUX(1,1), RESICJCMX(1,1), 2*NMESHES, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, IERR)

         DEALLOCATE(RESMAXV_AUX, DIVMNX_AUX, DIVVOLMNX_AUX, IJKRM_AUX, IJKMNX_AUX, DIVVOLIJKMNX_AUX, DIVVOLICJCMNX_AUX, &
                    DIVICJCMNX_AUX, VOLMNX_AUX, RESICJCMX_AUX, RESVOLMX_AUX, XYZMNX_AUX)
      ENDIF
      IF (MY_RANK==0) THEN
         WRITE(LU_ERR,*) ' '
         WRITE(LU_ERR,*) "N Step    =",ICYC," T, DT=",TLOC,DTLOC
         NMV(1)=MINLOC(DIVMNX(LOW_IND ,1:NMESHES),DIM=1)
         WRITE(LU_ERR,*) "Div Min   =",NMV(1),DIVMNX(LOW_IND ,NMV(1)),IJKMNX(IAXIS:KAXIS,LOW_IND ,NMV(1)),&
         XYZMNX(IAXIS:KAXIS,LOW_IND ,NMV(1)),&
         DIVICJCMNX(1:2,LOW_IND,NMV(1)),VOLMNX(LOW_IND,NMV(1))
         NMV(1)=MAXLOC(DIVMNX(HIGH_IND ,1:NMESHES),DIM=1)
         WRITE(LU_ERR,*) "Div Max   =",NMV(1),DIVMNX(HIGH_IND,NMV(1)),IJKMNX(IAXIS:KAXIS,HIGH_IND,NMV(1)),&
         XYZMNX(IAXIS:KAXIS,HIGH_IND,NMV(1)),&
         DIVICJCMNX(1:2,HIGH_IND,NMV(1)),VOLMNX(HIGH_IND,NMV(1))

         NMV(1)=MAXLOC(RESMAXV(1:NMESHES),DIM=1)
         WRITE(LU_ERR,*) "Res Max   =",NMV(1),RESMAXV(NMV(1)),IJKRM(IAXIS:KAXIS,NMV(1)),RESICJCMX(1:2,NMV(1)),RESVOLMX(NMV(1))

         NMV(1)=MINLOC(DIVVOLMNX(LOW_IND ,1:NMESHES),DIM=1)
         WRITE(LU_ERR,*) "DivVol Min=",NMV(1),DIVVOLMNX(LOW_IND ,NMV(1)),DIVVOLIJKMNX(IAXIS:KAXIS,LOW_IND ,NMV(1)),&
         DIVVOLICJCMNX(1:2,LOW_IND,NMV(1))
         NMV(1)=MAXLOC(DIVVOLMNX(HIGH_IND ,1:NMESHES),DIM=1)
         WRITE(LU_ERR,*) "DivVol Max=",NMV(1),DIVVOLMNX(HIGH_IND,NMV(1)),DIVVOLIJKMNX(IAXIS:KAXIS,HIGH_IND,NMV(1)),&
         DIVVOLICJCMNX(1:2,HIGH_IND,NMV(1))
      ENDIF
   ENDIF
ENDIF DEBUG_CCREGION_SCALAR_TRANSPORT_IF

! DeAllocate div Containers
DEALLOCATE( RESMAXV, DIVMNX, DIVVOLMNX )
DEALLOCATE( IJKRM, IJKMNX, DIVVOLIJKMNX, DIVVOLICJCMNX, RESVOLMX, RESICJCMX )
DEALLOCATE( XYZMNX )
RETURN
END SUBROUTINE  CCIBM_CHECK_DIVERGENCE


! ----------------------------- MASS_CONSERVE_INIT ------------------------------

SUBROUTINE MASS_CONSERVE_INIT

USE MPI_F08

! Local Variables:
INTEGER :: NM,IW,I,J,K,ICC,JCC
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC

INTEGER :: IERR

! Allocate and set FLXTINT_SPEC_MASS to zero
ALLOCATE( VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS), FLXTINT_SPEC_MASS(1:N_TOTAL_SCALARS), &
          VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS) )
FLXTINT_SPEC_MASS(1:N_TOTAL_SCALARS) = 0._EB
VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS)= 0._EB

! Allocate and compute initial mass integrals for species:
MESH_LOOP : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE
   CALL POINT_TO_MESH(NM)

   ! Allocate flux containers in EXTERNAL_WALL
   DO IW=1,N_EXTERNAL_WALL_CELLS
      WC => WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE

      EWC=>EXTERNAL_WALL(IW)

      ! Advective Fluxes:
      ALLOCATE(EWC%FVN(1:N_TOTAL_SCALARS),EWC%FVNS(1:N_TOTAL_SCALARS))
      EWC%FVN(1:N_TOTAL_SCALARS) = 0._EB
      EWC%FVNS(1:N_TOTAL_SCALARS)= 0._EB

      ! Diffusive Fluxes:
      ALLOCATE(EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS),EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS))
      EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = 0._EB
      EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS)= 0._EB

   ENDDO

   ! Compute initial mass integrals:
   ! First compute rhoZZ Volume integrals:
   CC_IBM_IF : IF (CC_IBM) THEN

      ! Now Compute, discard if solid:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_CGSC) /= IBM_GASPHASE) CYCLE
               VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS) = VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS) + &
                                    DX(I)*DY(J)*DZ(K)*RHO(I,J,K)*ZZ(I,J,K,1:N_TOTAL_SCALARS)
            ENDDO
         ENDDO
      ENDDO

      ! Now do cut-cells:
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         DO JCC=1,CUT_CELL(ICC)%NCELL
            VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS) = VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS) + &
            CUT_CELL(ICC)%VOLUME(JCC)*CUT_CELL(ICC)%RHO(JCC)* &
            CUT_CELL(ICC)%ZZ(1:N_TOTAL_SCALARS,JCC)
         ENDDO
      ENDDO

   ELSE ! Regular integral in the GASPHASE

      ! Now Compute, discard if solid:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
               VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS) = VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS) + &
                                    DX(I)*DY(J)*DZ(K)*RHO(I,J,K)*ZZ(I,J,K,1:N_TOTAL_SCALARS)
            ENDDO
         ENDDO
      ENDDO

   ENDIF CC_IBM_IF

ENDDO MESH_LOOP

VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS)=VOLINT_SPEC_MASS_0(1:N_TOTAL_SCALARS)
IF(N_MPI_PROCESSES>1) THEN
   CALL MPI_ALLREDUCE(VOLINT_SPEC_MASS(1), VOLINT_SPEC_MASS_0(1), N_TOTAL_SCALARS, MPI_DOUBLE_PRECISION, &
                      MPI_SUM, MPI_COMM_WORLD, IERR)
ENDIF

RETURN
END SUBROUTINE MASS_CONSERVE_INIT

! ----------------------- CHECK_SPEC_TRANSPORT_CONSERVE -------------------------

SUBROUTINE CHECK_SPEC_TRANSPORT_CONSERVE(T,DT,DIAGNOSTICS)

USE MPI_F08

REAL(EB), INTENT(IN) :: T,DT
LOGICAL,  INTENT(IN) :: DIAGNOSTICS

! Local Variables:
INTEGER :: NM, N, IW, I, J ,K, II, JJ, KK, IOR, ICC, JCC
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC
REAL(EB) :: DMWS(1:N_TOTAL_SCALARS),DMW(1:N_TOTAL_SCALARS)

REAL(EB) :: FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS)
REAL(EB) :: VOLINT_SPEC_MASS_AUX(1:N_TOTAL_SCALARS),FLXDT_SPEC_MASS_AUX(1:N_TOTAL_SCALARS)

INTEGER :: IERR

LOGICAL, SAVE :: FIRST_CALL=.TRUE.

SELECT CASE (PERIODIC_TEST)
   CASE DEFAULT
      IF (PROJECTION .AND. ICYC<=1) RETURN
   CASE (5,8)
      RETURN
   CASE (7,11)
      ! CONTINUE
END SELECT

! First compute rhoZZ Volume integrals:
VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) = 0._EB
CC_IBM_IF : IF (CC_IBM) THEN

   MESH_LOOP1 : DO NM=1,NMESHES

      IF (PROCESS(NM)/=MY_RANK) CYCLE
      CALL POINT_TO_MESH(NM)

      ! Now Compute, discard if solid:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (CCVAR(I,J,K,IBM_CGSC) /= IBM_GASPHASE) CYCLE
               VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) = VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) + &
                                DX(I)*DY(J)*DZ(K)*RHO(I,J,K)*ZZ(I,J,K,1:N_TOTAL_SCALARS)
            ENDDO
         ENDDO
      ENDDO

      ! Now do cut-cells:
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         DO JCC=1,CUT_CELL(ICC)%NCELL
            VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) = VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) + &
            CUT_CELL(ICC)%VOLUME(JCC)*CUT_CELL(ICC)%RHO(JCC)* &
            CUT_CELL(ICC)%ZZ(1:N_TOTAL_SCALARS,JCC)
         ENDDO
      ENDDO

   ENDDO MESH_LOOP1

ELSE ! Regular integral in the GASPHASE

   MESH_LOOP2 : DO NM=1,NMESHES

      IF (PROCESS(NM)/=MY_RANK) CYCLE
      CALL POINT_TO_MESH(NM)

      ! Now Compute, discard if solid:
      DO K=1,KBAR
         DO J=1,JBAR
            DO I=1,IBAR
               IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
               VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) = VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) + &
                                DX(I)*DY(J)*DZ(K)*RHO(I,J,K)*ZZ(I,J,K,1:N_TOTAL_SCALARS)
            ENDDO
         ENDDO
      ENDDO

   ENDDO MESH_LOOP2

ENDIF CC_IBM_IF
! Here MPI_ALLREDUCE SUM VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS) across processes:
VOLINT_SPEC_MASS_AUX(1:N_TOTAL_SCALARS) = VOLINT_SPEC_MASS(1:N_TOTAL_SCALARS)
IF (N_MPI_PROCESSES>1) THEN
   CALL MPI_ALLREDUCE(VOLINT_SPEC_MASS_AUX(1), VOLINT_SPEC_MASS(1), N_TOTAL_SCALARS, MPI_DOUBLE_PRECISION, &
                      MPI_SUM, MPI_COMM_WORLD, IERR)
ENDIF

! Then add DrhoZZ from Domain boundaries to time accumulated values:
FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) = 0._EB
MESH_LOOP3 : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE
   CALL POINT_TO_MESH(NM)

   EWC_LOOP : DO IW=1,N_EXTERNAL_WALL_CELLS
      WC => WALL(IW)
      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE
      EWC=>EXTERNAL_WALL(IW)

      ! WRITE(LU_ERR,*) size(EXTERNAL_WALL(IW)%FVN,DIM=1)

      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK
      IOR = WC%ONE_D%IOR

      ! Do SSPRK2 integral of fluxes across EXTERNAL wall cell, DELTAMASS=0 for time level n:
      !                         DT*(ADV+DIFF)^n
      DMWS(1:N_TOTAL_SCALARS) = DT*(EWC%FVN(1:N_TOTAL_SCALARS)-EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS))
      DMW(1:N_TOTAL_SCALARS)  = 0.5_EB*( DMWS(1:N_TOTAL_SCALARS) + &
                                DT*(EWC%FVNS(1:N_TOTAL_SCALARS)-EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS)))

      ! ADD TO FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS):
      SELECT CASE(IOR)
      CASE(1) ! Low FACE: Add delta mass due to FLX.
         FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) = FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) + &
                                              DMW(1:N_TOTAL_SCALARS)*DY(JJ)*DZ(KK)
      CASE(-1) ! High FACE: Subtract mass due to FLX.
         FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) = FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) - &
                                              DMW(1:N_TOTAL_SCALARS)*DY(JJ)*DZ(KK)
      CASE(2) ! Low FACE: Add delta mass due to FLX.
         FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) = FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) + &
                                              DMW(1:N_TOTAL_SCALARS)*DX(II)*DZ(KK)
      CASE(-2) ! High FACE: Subtract mass due to FLX.
         FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) = FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) - &
                                              DMW(1:N_TOTAL_SCALARS)*DX(II)*DZ(KK)
      CASE(3) ! Low FACE: Add delta mass due to FLX.
         FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) = FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) + &
                                              DMW(1:N_TOTAL_SCALARS)*DX(II)*DY(JJ)
      CASE(-3) ! High FACE: Subtract mass due to FLX.
         FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) = FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) - &
                                              DMW(1:N_TOTAL_SCALARS)*DX(II)*DY(JJ)
      END SELECT

   ENDDO EWC_LOOP

ENDDO MESH_LOOP3

! Here MPI_ALLREDUCE SUM FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS) across processes:
FLXDT_SPEC_MASS_AUX(1:N_TOTAL_SCALARS) = FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS)
IF (N_MPI_PROCESSES>1) THEN
   CALL MPI_ALLREDUCE(FLXDT_SPEC_MASS_AUX(1), FLXDT_SPEC_MASS(1), N_TOTAL_SCALARS, MPI_DOUBLE_PRECISION, &
                      MPI_SUM, MPI_COMM_WORLD, IERR)
ENDIF

FLXTINT_SPEC_MASS(1:N_TOTAL_SCALARS) = FLXTINT_SPEC_MASS(1:N_TOTAL_SCALARS) + &
                                       FLXDT_SPEC_MASS(1:N_TOTAL_SCALARS)
! Check difference:
If (DIAGNOSTICS .AND. MY_RANK==0) THEN
    WRITE(LU_ERR,'(A)') 'Scalar,   Total Mass Vol Integral,   Total Mass Flx Time Integral,   Difference'
    DO N=1,N_TOTAL_SCALARS
       WRITE(LU_ERR,'(I4,3E25.3)') N,VOLINT_SPEC_MASS(N), VOLINT_SPEC_MASS_0(N)+FLXTINT_SPEC_MASS(N), &
                         VOLINT_SPEC_MASS(N)-(VOLINT_SPEC_MASS_0(N)+FLXTINT_SPEC_MASS(N))
    ENDDO
ENDIF

! Write To file:
IF(MY_RANK==0) THEN
   IF (FIRST_CALL) THEN
      OPEN(unit=33, file="./Scalars_Integral.res", status='unknown')
      CLOSE(33)
      FIRST_CALL = .FALSE.
   ENDIF

   OPEN(unit=33, file="./Scalars_Integral.res", status='old', position='append')
   DO N=1,N_TOTAL_SCALARS
      write(33,*) T,N,VOLINT_SPEC_MASS(N), VOLINT_SPEC_MASS_0(N)+FLXTINT_SPEC_MASS(N), &
                      VOLINT_SPEC_MASS(N)-(VOLINT_SPEC_MASS_0(N)+FLXTINT_SPEC_MASS(N))
   ENDDO
   CLOSE(33)
ENDIF

RETURN
END SUBROUTINE CHECK_SPEC_TRANSPORT_CONSERVE


! ---------------------------- SET_DOMAINADVLX_3D -------------------------------

SUBROUTINE SET_DOMAINADVFLX_3D(UU,VV,WW,PREDCORR)

REAL(EB), POINTER, DIMENSION(:,:,:) :: UU,VV,WW
LOGICAL, INTENT(IN) :: PREDCORR

! Local Variables:
INTEGER :: IW, II, JJ, KK, IOR
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC


! Now store advective fluxes:
EWALL_LOOP : DO IW=1,N_EXTERNAL_WALL_CELLS

   WC => WALL(IW)
   IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY .OR. &
       WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE
   EWC=>EXTERNAL_WALL(IW)

   II  = WC%ONE_D%II
   JJ  = WC%ONE_D%JJ
   KK  = WC%ONE_D%KK
   IOR = WC%ONE_D%IOR

   IF (PREDCORR) THEN
      ! Diffusive fluxes related to ZZ
      SELECT CASE(IOR)
      CASE(1)
         EWC%FVN(1:N_TOTAL_SCALARS) = FX(II,JJ,KK,1:N_TOTAL_SCALARS)*UU(II,JJ,KK)
      CASE(-1)
         EWC%FVN(1:N_TOTAL_SCALARS) = FX(II-1,JJ,KK,1:N_TOTAL_SCALARS)*UU(II-1,JJ,KK)
      CASE(2)
         EWC%FVN(1:N_TOTAL_SCALARS) = FY(II,JJ,KK,1:N_TOTAL_SCALARS)*VV(II,JJ,KK)
      CASE(-2)
         EWC%FVN(1:N_TOTAL_SCALARS) = FY(II,JJ-1,KK,1:N_TOTAL_SCALARS)*VV(II,JJ-1,KK)
      CASE(3)
         EWC%FVN(1:N_TOTAL_SCALARS) = FZ(II,JJ,KK,1:N_TOTAL_SCALARS)*WW(II,JJ,KK)
      CASE(-3)
         EWC%FVN(1:N_TOTAL_SCALARS) = FZ(II,JJ,KK-1,1:N_TOTAL_SCALARS)*WW(II,JJ,KK-1)
      END SELECT
   ELSE
      ! Diffusive fluxes computed from ZZS
      SELECT CASE(IOR)
      CASE(1)
         EWC%FVNS(1:N_TOTAL_SCALARS) = FX(II,JJ,KK,1:N_TOTAL_SCALARS)*UU(II,JJ,KK)
      CASE(-1)
         EWC%FVNS(1:N_TOTAL_SCALARS) = FX(II-1,JJ,KK,1:N_TOTAL_SCALARS)*UU(II-1,JJ,KK)
      CASE(2)
         EWC%FVNS(1:N_TOTAL_SCALARS) = FY(II,JJ,KK,1:N_TOTAL_SCALARS)*VV(II,JJ,KK)
      CASE(-2)
         EWC%FVNS(1:N_TOTAL_SCALARS) = FY(II,JJ-1,KK,1:N_TOTAL_SCALARS)*VV(II,JJ-1,KK)
      CASE(3)
         EWC%FVNS(1:N_TOTAL_SCALARS) = FZ(II,JJ,KK,1:N_TOTAL_SCALARS)*WW(II,JJ,KK)
      CASE(-3)
         EWC%FVNS(1:N_TOTAL_SCALARS) = FZ(II,JJ,KK-1,1:N_TOTAL_SCALARS)*WW(II,JJ,KK-1)
      END SELECT
   ENDIF

ENDDO EWALL_LOOP



RETURN
END SUBROUTINE SET_DOMAINADVFLX_3D

! ---------------------------- SET_DOMAINDIFFLX_3D ------------------------------

SUBROUTINE SET_DOMAINDIFFLX_3D(ZZP,RHO_D_DZDX,RHO_D_DZDY,RHO_D_DZDZ,PREDCORR)

REAL(EB), INTENT(IN),POINTER, DIMENSION(:,:,:,:) :: ZZP
REAL(EB), INTENT(IN), POINTER, DIMENSION(:,:,:,:) :: RHO_D_DZDX,RHO_D_DZDY,RHO_D_DZDZ
LOGICAL, INTENT(IN) :: PREDCORR

! Local Variables:
INTEGER :: N, IW
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC
REAL(EB) :: RHO_D_DZDN_GET(1:N_TRACKED_SPECIES),RHO_D_DZDN(1:N_TOTAL_SCALARS)
INTEGER :: II,JJ,KK,IIG,JJG,KKG,IOR,N_ZZ_MAX

! This routine assumes this call has been made before calling it:
! CALL POINT_TO_MESH(NM)

! Now loop species and external wall-cells:
SPECIES_GT_1_IF: IF (N_TOTAL_SCALARS>1) THEN

   ! Get rho*D_n grad Z_n at domain boundaries:

   EWALL_LOOP : DO IW=1,N_EXTERNAL_WALL_CELLS

      WC => WALL(IW)

      IF (WC%BOUNDARY_TYPE==NULL_BOUNDARY .OR. &
          WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY) CYCLE EWALL_LOOP

      EWC=>EXTERNAL_WALL(IW)

      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK

      IIG = WC%ONE_D%IIG
      JJG = WC%ONE_D%JJG
      KKG = WC%ONE_D%KKG

      IOR = WC%ONE_D%IOR

      IF (WC%BOUNDARY_TYPE==OPEN_BOUNDARY) THEN

         IF (PREDCORR) THEN
            ! Diffusive fluxes related to ZZ
            SELECT CASE(IOR)
            CASE(1)
               EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = RHO_D_DZDX(II,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(-1)
               EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = RHO_D_DZDX(II-1,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(2)
               EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = RHO_D_DZDY(II,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(-2)
               EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = RHO_D_DZDY(II,JJ-1,KK,1:N_TOTAL_SCALARS)
            CASE(3)
               EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = RHO_D_DZDZ(II,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(-3)
               EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = RHO_D_DZDZ(II,JJ,KK-1,1:N_TOTAL_SCALARS)
            END SELECT
         ELSE
            ! Diffusive fluxes computed from ZZS
            SELECT CASE(ABS(IOR))
            CASE(1)
               EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS) = RHO_D_DZDX(II,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(-1)
               EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS) = RHO_D_DZDX(II-1,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(2)
               EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS) = RHO_D_DZDY(II,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(-2)
               EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS) = RHO_D_DZDY(II,JJ-1,KK,1:N_TOTAL_SCALARS)
            CASE(3)
               EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS) = RHO_D_DZDZ(II,JJ,KK,1:N_TOTAL_SCALARS)
            CASE(-3)
               EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS) = RHO_D_DZDZ(II,JJ,KK-1,1:N_TOTAL_SCALARS)
            END SELECT
         ENDIF

      ELSE ! WC%BOUNDARY_TYPE/=OPEN_BOUNDARY
         ! Recompute diffusive fluxes:
         N_ZZ_MAX = MAXLOC(WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES),1)
         SPECIES_LOOP: DO N=1,N_TOTAL_SCALARS
            ! This will only work if N_TOTAL_SCALARS=N_TRACKED_SPECIES, i.e.
            ! WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES), but loop  N=1,N_TOTAL_SCALARS
            RHO_D_DZDN(N) = 2._EB*WC%ONE_D%RHO_D_F(N)*(ZZP(IIG,JJG,KKG,N)-WC%ONE_D%ZZ_F(N))*WC%ONE_D%RDN
            IF (N==N_ZZ_MAX) THEN
               RHO_D_DZDN_GET(1:N_TRACKED_SPECIES) = &
                 2._EB*WC%ONE_D%RHO_D_F(1:N_TRACKED_SPECIES)*  &
               (ZZP(IIG,JJG,KKG,1:N_TRACKED_SPECIES)-WC%ONE_D%ZZ_F(1:N_TRACKED_SPECIES))*WC%ONE_D%RDN
               RHO_D_DZDN(N) = -(SUM(RHO_D_DZDN_GET(1:N_TRACKED_SPECIES))-RHO_D_DZDN(N))
            ENDIF

         ENDDO SPECIES_LOOP

         IF (PREDCORR) THEN
            EWC%RHO_D_DZDN(1:N_TOTAL_SCALARS) = RHO_D_DZDN(1:N_TOTAL_SCALARS)
         ELSE
            EWC%RHO_D_DZDNS(1:N_TOTAL_SCALARS) = RHO_D_DZDN(1:N_TOTAL_SCALARS)
         ENDIF

      ENDIF ! WC%BOUNDARY_TYPE

   ENDDO EWALL_LOOP

ENDIF SPECIES_GT_1_IF


RETURN
END SUBROUTINE SET_DOMAINDIFFLX_3D

! ---------------------------- POTENTIAL_FLOW_INIT ------------------------------

SUBROUTINE POTENTIAL_FLOW_INIT

#ifdef WITH_MKL
USE MKL_CLUSTER_SPARSE_SOLVER
#endif /* WITH_MKL */

USE MPI_F08

! Local Variables:
INTEGER :: MAXFCT, MNUM, MTYPE, PHASE, NRHS, ERROR, MSGLVL
#ifdef WITH_MKL
INTEGER :: PERM(1)
#endif
INTEGER :: NM, IW, IIG, JJG, KKG, IOR, IROW, I, J, K, X1AXIS, ICF, IFACE, NFACE
TYPE (WALL_TYPE), POINTER :: WC
REAL(EB):: IDX, AF, VAL, TNOW, DHDXN, HVAL, HM1, HP1
!REAL(EB), POINTER, DIMENSION(:,:,:) :: HP
INTEGER :: IND(LOW_IND:HIGH_IND), IND_LOC(LOW_IND:HIGH_IND)

! Set FREEZE_VELOCITY to .TRUE., no velocity evolution along the time integration.
FREEZE_VELOCITY=.TRUE.

! Here we define A set of boundary conditions on the Domain boundaries such that we
! Define rhs F_H, here we use Source defined for potential flow solution:
F_H(1:NUNKH_LOCAL) = 0._EB
X_H(1:NUNKH_LOCAL) = 0._EB

! Meshes Loop:
MESHES_LOOP : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   ! Then BCs:
   WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS

      WC => WALL(IW)

      ! NEUMANN boundaries:
      IF_NEUMANN: IF (WC%PRESSURE_BC_INDEX==NEUMANN) THEN

         ! Gasphase cell indexes:
         IIG   = WC%ONE_D%IIG
         JJG   = WC%ONE_D%JJG
         KKG   = WC%ONE_D%KKG
         IOR   = WC%ONE_D%IOR

         DHDXN = -WC%ONE_D%U_NORMAL_0

         ! Define cell size, normal to WC:
         SELECT CASE (IOR)
         CASE(-1) ! -IAXIS oriented, high face of IIG cell.
            AF  =  DY(JJG)*DZ(KKG)
            VAL = -DHDXN*AF
         CASE( 1) ! +IAXIS oriented, low face of IIG cell.
            AF  =  DY(JJG)*DZ(KKG)
            VAL =  DHDXN*AF
         CASE(-2) ! -JAXIS oriented, high face of JJG cell.
            AF  =  DX(IIG)*DZ(KKG)
            VAL = -DHDXN*AF
         CASE( 2) ! +JAXIS oriented, low face of JJG cell.
            AF  =  DX(IIG)*DZ(KKG)
            VAL =  DHDXN*AF
         CASE(-3) ! -KAXIS oriented, high face of KKG cell.
            AF  =  DX(IIG)*DY(JJG)
            VAL = -DHDXN*AF
            WRITE(LU_ERR,*) "POTENTIAL_FLOW_INIT: high KAXIS H BC set to NEUMANN, should be DIRICHLET."
         CASE( 3) ! +KAXIS oriented, low face of KKG cell.
            AF  =  DX(IIG)*DY(JJG)
            VAL =  DHDXN*AF
         END SELECT

         ! Row number:
         IROW = CCVAR(IIG,JJG,KKG,IBM_UNKH) - UNKH_IND(NM_START) ! Local numeration.

         ! Add to F_H:
         F_H(IROW) = F_H(IROW) + VAL

      ENDIF IF_NEUMANN

      ! DIRICHLET boundaries, Modify diagonal coefficient on D_MAT_H:
      IF_DIRICHLET: IF (WC%PRESSURE_BC_INDEX==DIRICHLET) THEN

         ! Gasphase cell indexes:
         IIG   = WC%ONE_D%IIG
         JJG   = WC%ONE_D%JJG
         KKG   = WC%ONE_D%KKG
         IOR   = WC%ONE_D%IOR

         ! Define cell size, normal to WC:
         HVAL= 0._EB ! Same sign for all cases.
         SELECT CASE (IOR)
         CASE(-1) ! -IAXIS oriented, high face of IIG cell.
            IDX = 1._EB / DXN(IIG)
            AF  =  DY(JJG)*DZ(KKG)
            VAL = -2._EB*IDX*AF*HVAL
            WRITE(LU_ERR,*) "POTENTIAL_FLOW_INIT: high IAXIS H BC set to DIRICHLET, should be NEUMANN."
         CASE( 1) ! +IAXIS oriented, low face of IIG cell.
            IDX = 1._EB / DXN(IIG-1)
            AF  =  DY(JJG)*DZ(KKG)
            VAL = -2._EB*IDX*AF*HVAL
            WRITE(LU_ERR,*) "POTENTIAL_FLOW_INIT: low IAXIS H BC set to DIRICHLET, should be NEUMANN."
         CASE(-2) ! -JAXIS oriented, high face of JJG cell.
            IDX = 1._EB / DYN(JJG)
            AF  =  DX(IIG)*DZ(KKG)
            VAL = -2._EB*IDX*AF*HVAL
            WRITE(LU_ERR,*) "POTENTIAL_FLOW_INIT: high JAXIS H BC set to DIRICHLET, should be NEUMANN."
         CASE( 2) ! +JAXIS oriented, low face of JJG cell.
            IDX = 1._EB / DYN(JJG-1)
            AF  =  DX(IIG)*DZ(KKG)
            VAL = -2._EB*IDX*AF*HVAL
            WRITE(LU_ERR,*) "POTENTIAL_FLOW_INIT: low JAXIS H BC set to DIRICHLET, should be NEUMANN."
         CASE(-3) ! -KAXIS oriented, high face of KKG cell.
            IDX = 1._EB / DZN(KKG)
            AF  =  DX(IIG)*DY(JJG)
            VAL = -2._EB*IDX*AF*HVAL
         CASE( 3) ! +KAXIS oriented, low face of KKG cell.
            IDX = 1._EB / DZN(KKG-1)
            AF  =  DX(IIG)*DY(JJG)
            VAL = -2._EB*IDX*AF*HVAL
            WRITE(LU_ERR,*) "POTENTIAL_FLOW_INIT: low KAXIS H BC set to DIRICHLET, should be NEUMANN."
         END SELECT

         ! Row number:
         IROW = CCVAR(IIG,JJG,KKG,IBM_UNKH) - UNKH_IND(NM_START) ! Local numeration.

         ! Add to F_H:
         F_H(IROW) = F_H(IROW) + VAL

      ENDIF IF_DIRICHLET

   ENDDO WALL_CELL_LOOP

ENDDO MESHES_LOOP


! Solve:
NRHS   =  1
MAXFCT =  1
MNUM   =  1
ERROR  =  0 ! initialize error flag
MSGLVL =  0 ! print statistical information
IF ( H_MATRIX_INDEFINITE ) THEN
   MTYPE  = -2 ! symmetric indefinite
ELSE ! positive definite
   MTYPE  =  2
ENDIF

!.. Solve system:
IPARM(8) = 0 ! max numbers of iterative refinement steps
PHASE = 33   ! Solve system back-forth substitution.
TNOW=CURRENT_TIME()
! PARDISO:
! CALL PARDISO(PT_H, MAXFCT, MNUM, MTYPE, PHASE, NUNKH_TOTAL, &
!      A_H, IA_H, JA_H, PERM, NRHS, IPARM, MSGLVL, F_H, X_H, ERROR)
! WRITE(LU_ERR,*) "POTENTIAL_FLOW PARDISO time=",CURRENT_TIME()-TNOW,ERROR

#ifdef WITH_MKL
CALL CLUSTER_SPARSE_SOLVER(PT_H, MAXFCT, MNUM, MTYPE, PHASE, NUNKH_TOTAL, &
             A_H, IA_H, JA_H, PERM, NRHS, IPARM, MSGLVL, F_H, X_H, MPI_COMM_WORLD, ERROR)
IF (MY_RANK==0) WRITE(LU_ERR,*) "POTENTIAL_FLOW CLUSTER_SPARSE_SOLVER time=",CURRENT_TIME()-TNOW,ERROR

#else
IF (MY_RANK==0) THEN
   WRITE(LU_ERR,*) 'Can not solve Potential flow problem on domain.'
   WRITE(LU_ERR,*) 'MKL Library compile flag was not defined.'
ENDIF
! Some error - stop flag.
RETURN
#endif /* WITH_MKL */

! Use result to define potential flow velocities:
! Meshes Loop:
MESHES_LOOP2 : DO NM=1,NMESHES

   IF (PROCESS(NM)/=MY_RANK) CYCLE

   CALL POINT_TO_MESH(NM)

   ! Now define velocities V = -G(H):
   ! First Regular gasphase velocities:
   ! IAXIS faces:
   X1AXIS = IAXIS
   DO IFACE=1,MESHES(NM)%NREGFACE_H(X1AXIS)

      I  = MESHES(NM)%REGFACE_IAXIS_H(IFACE)%IJK(IAXIS)
      J  = MESHES(NM)%REGFACE_IAXIS_H(IFACE)%IJK(JAXIS)
      K  = MESHES(NM)%REGFACE_IAXIS_H(IFACE)%IJK(KAXIS)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%CCVAR(I  ,J,K,IBM_UNKH)
      IND(HIGH_IND) = MESHES(NM)%CCVAR(I+1,J,K,IBM_UNKH)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM_START)

      ! Face dx:
      IDX= 1._EB/DXN(I)

      HM1 = X_H(IND_LOC(LOW_IND))
      HP1 = X_H(IND_LOC(HIGH_IND))
      U(I,J,K) = -IDX*(HP1-HM1)
      US(I,J,K)= U(I,J,K)
   ENDDO

   ! JAXIS faces:
   X1AXIS = JAXIS
   DO IFACE=1,MESHES(NM)%NREGFACE_H(X1AXIS)

      I  = MESHES(NM)%REGFACE_JAXIS_H(IFACE)%IJK(IAXIS)
      J  = MESHES(NM)%REGFACE_JAXIS_H(IFACE)%IJK(JAXIS)
      K  = MESHES(NM)%REGFACE_JAXIS_H(IFACE)%IJK(KAXIS)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%CCVAR(I,J  ,K,IBM_UNKH)
      IND(HIGH_IND) = MESHES(NM)%CCVAR(I,J+1,K,IBM_UNKH)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM_START)

      ! Face dx:
      IDX= 1._EB/DYN(J)

      HM1 = X_H(IND_LOC(LOW_IND))
      HP1 = X_H(IND_LOC(HIGH_IND))
      V(I,J,K) = -IDX*(HP1-HM1)
      VS(I,J,K)= V(I,J,K)
   ENDDO

   ! KAXIS faces:
   X1AXIS = KAXIS
   DO IFACE=1,MESHES(NM)%NREGFACE_H(X1AXIS)

      I  = MESHES(NM)%REGFACE_KAXIS_H(IFACE)%IJK(IAXIS)
      J  = MESHES(NM)%REGFACE_KAXIS_H(IFACE)%IJK(JAXIS)
      K  = MESHES(NM)%REGFACE_KAXIS_H(IFACE)%IJK(KAXIS)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%CCVAR(I,J,K  ,IBM_UNKH)
      IND(HIGH_IND) = MESHES(NM)%CCVAR(I,J,K+1,IBM_UNKH)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM_START)

      ! Face dx:
      IDX= 1._EB/DZN(K)

      HM1 = X_H(IND_LOC(LOW_IND))
      HP1 = X_H(IND_LOC(HIGH_IND))
      W(I,J,K) = -IDX*(HP1-HM1)
      WS(I,J,K)= W(I,J,K)

   ENDDO

   ! Domain boundary collocated velocities:
   ! Low Z:
   K = 0
   DO J=1,JBAR
      DO I=1,IBAR
         W(I,J,K) = 1._EB
      ENDDO
   ENDDO
   ! High Z:
   K = KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         ! Unknowns on related cells:
         IND(LOW_IND)     = MESHES(NM)%CCVAR(I,J,K,IBM_UNKH)
         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM_START) ! All row indexes must refer to ind_loc.
         ! Face dx:
         IDX= 1._EB/DZN(K)

         HM1 = X_H(IND_LOC(LOW_IND))
         W(I,J,K) = 2._EB*IDX*HM1
      ENDDO
   ENDDO


   ! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   DO IFACE=1,MESHES(NM)%IBM_NRCFACE_H

      I      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(IAXIS)
      J      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(JAXIS)
      K      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS+1)

      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(LOW_IND)
      IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(HIGH_IND)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM_START)

      IDX = 1._EB / ( MESHES(NM)%IBM_RCFACE_H(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                      MESHES(NM)%IBM_RCFACE_H(IFACE)%XCEN(X1AXIS,LOW_IND) )

      HM1 = X_H(IND_LOC(LOW_IND))
      HP1 = X_H(IND_LOC(HIGH_IND))

      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            U(I,J,K) = -IDX*(HP1-HM1)
            US(I,J,K)= U(I,J,K)
         CASE(JAXIS)
            V(I,J,K) = -IDX*(HP1-HM1)
            VS(I,J,K)= V(I,J,K)
         CASE(KAXIS)
            W(I,J,K) = -IDX*(HP1-HM1)
            WS(I,J,K)= W(I,J,K)
      END SELECT

   ENDDO

   ! Finally Gasphase cut-faces:
   IF (.NOT. PRES_ON_CARTESIAN) THEN

   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

      CUT_FACE(ICF)%VEL(:) = 0._EB ! INBOUNDARY cut-faces velocities set to 0.
      CUT_FACE(ICF)%VELS(:)= 0._EB

      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE

      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      DO IFACE=1,CUT_FACE(ICF)%NFACE

         !% Unknowns on related cells:
         IND(LOW_IND)  = CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
         IND(HIGH_IND) = CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)

         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM_START) ! All row indexes must refer to ind_loc.
         IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM_START)

         IDX= 1._EB/ ( CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE) - &
                       CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE) )

         HM1 = X_H(IND_LOC(LOW_IND))
         HP1 = X_H(IND_LOC(HIGH_IND))

         CUT_FACE(ICF)%VEL(IFACE)  = -IDX*(HP1-HM1)
         CUT_FACE(ICF)%VELS(IFACE) =  CUT_FACE(ICF)%VEL(IFACE)

      ENDDO

   ENDDO

  ELSE ! PRES_ON_CARTESIAN

   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

      CUT_FACE(ICF)%VEL(:) = 0._EB ! INBOUNDARY cut-faces velocities set to 0.
      CUT_FACE(ICF)%VELS(:)= 0._EB

      IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE

      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

      IFACE=1
      !% Unknowns on related cells:
      IND(LOW_IND)  = CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
      IND(HIGH_IND) = CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM_START) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM_START)

      HM1 = X_H(IND_LOC(LOW_IND))
      HP1 = X_H(IND_LOC(HIGH_IND))

      NFACE = CUT_FACE(ICF)%NFACE
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            IDX = 1._EB/DXN(I)
            U(I,J,K) = -IDX*(HP1-HM1)
            US(I,J,K)= U(I,J,K)

            AF=DY(J)*DZ(K)/ SUM(CUT_FACE(ICF)%AREA(1:NFACE))
            CUT_FACE(ICF)%VEL(1:NFACE)  = AF*U(I,J,K)
            CUT_FACE(ICF)%VELS(1:NFACE) = AF*U(I,J,K)

         CASE(JAXIS)
            IDX= 1._EB/DYN(J)
            V(I,J,K) = -IDX*(HP1-HM1)
            VS(I,J,K)= V(I,J,K)

            AF=DX(I)*DZ(K)/ SUM(CUT_FACE(ICF)%AREA(1:NFACE))
            CUT_FACE(ICF)%VEL(1:NFACE)  = AF*V(I,J,K)
            CUT_FACE(ICF)%VELS(1:NFACE) = AF*V(I,J,K)

         CASE(KAXIS)
            IDX= 1._EB/DZN(K)
            W(I,J,K) = -IDX*(HP1-HM1)
            WS(I,J,K)= W(I,J,K)

            AF=DX(I)*DY(J)/ SUM(CUT_FACE(ICF)%AREA(1:NFACE))
            CUT_FACE(ICF)%VEL(1:NFACE)  = AF*W(I,J,K)
            CUT_FACE(ICF)%VELS(1:NFACE) = AF*W(I,J,K)

      END SELECT

   ENDDO

   ENDIF

ENDDO MESHES_LOOP2

RETURN
END SUBROUTINE POTENTIAL_FLOW_INIT

! -------------------------- LINEARFIELDS_INTERP_TEST ---------------------------

SUBROUTINE LINEARFIELDS_INTERP_TEST

USE MPI_F08
USE TURBULENCE, ONLY : WALL_MODEL
USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY

! Local Variables:
INTEGER :: NM, I, J ,K, X1AXIS, IFACE, ICF
REAL(EB):: XYZ(MAX_DIM),XYZ_PP(MAX_DIM),VAL_CC,VAL_CC_ANN
LOGICAL :: DO_CUT_FACE, DO_CUT_CELL, DO_RCCELL
REAL(EB):: L1_DIFF_CUT_FACE, L1_DIFF_CUTCELL, L1_DIFF_RCCELL
INTEGER :: NP_CUTFACE, NP_CUTCELL, NP_RCCELL
INTEGER :: ICC, NCELL, ICELL, IPROC, IERR

INTEGER :: VIND,EP,INPE,INT_NPE_LO,INT_NPE_HI
REAL(EB):: VAL_BP, VAL_EP, COEF_EP, COEF_BP, COEF, DCOEF(IAXIS:KAXIS)
REAL(EB):: UVW_EP(IAXIS:KAXIS,0:INT_N_EXT_PTS), DUVW_EP(IAXIS:KAXIS,IAXIS:KAXIS,0:INT_N_EXT_PTS)
INTEGER, PARAMETER :: MY_AXIS = KAXIS
REAL(EB) :: U_VELO(MAX_DIM),U_SURF(MAX_DIM),U_RELA(MAX_DIM)
REAL(EB) :: NN(MAX_DIM),SS(MAX_DIM),TT(MAX_DIM),VELN,U_NORM,U_ORTH,U_STRM,DUSDN_FP
INTEGER :: JCC, ICF1, ICF2, ICFA, ISIDE
REAL(EB):: X1F, IDX, CCM1, CCP1, TMPV(-1:0), RHOV(-1:0), MUV(-1:0), NU, MU_FACE, RHO_FACE
REAL(EB):: ZZ_GET(1:N_TRACKED_SPECIES), DXN_STRM, DXN_STRM2, SLIP_FACTOR, SRGH, U_NORM2, U_STRM2, U_TAU, Y_PLUS
REAL(EB), POINTER, DIMENSION(:,:,:) :: UU,VV,WW,RHOP
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP
INTEGER :: DAXIS
REAL(EB) :: L1_DIFF_CUT_FACE_UDX, L1_DIFF_CUT_FACE_UDY, L1_DIFF_CUT_FACE_UDZ
REAL(EB) :: L1_DIFF_CUT_FACE_VDX, L1_DIFF_CUT_FACE_VDY, L1_DIFF_CUT_FACE_VDZ
REAL(EB) :: L1_DIFF_CUT_FACE_WDX, L1_DIFF_CUT_FACE_WDY, L1_DIFF_CUT_FACE_WDZ

DO_CUT_FACE   =  .TRUE.
DO_CUT_CELL   =  .TRUE.
DO_RCCELL     =  .TRUE.

L1_DIFF_CUT_FACE = 0._EB
L1_DIFF_CUTCELL  = 0._EB
L1_DIFF_RCCELL   = 0._EB


L1_DIFF_CUT_FACE_UDX = 0._EB
L1_DIFF_CUT_FACE_UDY = 0._EB
L1_DIFF_CUT_FACE_UDZ = 0._EB

L1_DIFF_CUT_FACE_VDX = 0._EB
L1_DIFF_CUT_FACE_VDY = 0._EB
L1_DIFF_CUT_FACE_VDZ = 0._EB

L1_DIFF_CUT_FACE_WDX = 0._EB
L1_DIFF_CUT_FACE_WDY = 0._EB
L1_DIFF_CUT_FACE_WDZ = 0._EB

NP_CUTFACE       = 0
NP_CUTCELL       = 0
NP_RCCELL        = 0

! Initialize:
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   ! Initialize face, center variables with linear fielp phi(x,y,z) = 2*x + 3*y +4*z
   CALL LINEARFIELDS_INIT(NM)
ENDDO

CALL MESH_CC_EXCHANGE(1)
CALL MESH_CC_EXCHANGE(3)
CALL MESH_CC_EXCHANGE(4)
CALL MESH_CC_EXCHANGE(6)

! Main Mesh Loop:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM) ! already done in LINEARFIELDS_INIT(NM).

   UU => U
   VV => V
   WW => W
   RHOP => RHO
   ZZP  => ZZ

   ! Test that interpolation to faces and cell centroids gives the same phi values:
   ! Cut-faces and underlying Cartesian face centroid:
   IF (DO_CUT_FACE) THEN
      ICF_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH

         IF ( CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE

         I      = CUT_FACE(ICF)%IJK(IAXIS)
         J      = CUT_FACE(ICF)%IJK(JAXIS)
         K      = CUT_FACE(ICF)%IJK(KAXIS)
         X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

         DO IFACE=0,CUT_FACE(ICF)%NFACE

            ! First, underlying cartesian face centroid:
            SELECT CASE(X1AXIS)
              CASE(IAXIS)
                  XYZ(IAXIS:KAXIS) = (/ X(I), YC(J), ZC(K) /)
              CASE(JAXIS)
                  XYZ(IAXIS:KAXIS) = (/ XC(I), Y(J), ZC(K) /)
              CASE(KAXIS)
                  XYZ(IAXIS:KAXIS) = (/ XC(I), YC(J), Z(K) /)
            END SELECT
            IF (IFACE > 0) XYZ(IAXIS:KAXIS) = CUT_FACE(ICF)%XYZCEN(IAXIS:KAXIS,IFACE)

            UVW_EP = 0._EB; DUVW_EP = 0._EB
            DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
               DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                  INT_NPE_LO = CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
                  INT_NPE_HI = CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     VAL_EP = CUT_FACE(ICF)%INT_FVARS(INT_VEL_IND,INPE)
                     ! Interpolation coefficient from INPE to EP.
                     COEF = CUT_FACE(ICF)%INT_COEF(INPE)
                     ! Add to Velocity component VIND of EP:
                     UVW_EP(VIND,EP) = UVW_EP(VIND,EP) + COEF*VAL_EP

                     ! Now velocity derivatives:
                     DCOEF(IAXIS:KAXIS) = CUT_FACE(ICF)%INT_DCOEF(IAXIS:KAXIS,INPE)
                     DO DAXIS=IAXIS,KAXIS
                        DUVW_EP(DAXIS,VIND,EP) = DUVW_EP(DAXIS,VIND,EP) + DCOEF(DAXIS)*VAL_EP
                     ENDDO
                  ENDDO
               ENDDO
            ENDDO

            IF(INT_N_EXT_PTS==1) THEN
               ! Transform External points velocities into local coordinate system, defined by the velocity vector in
               ! the first external point, and the surface:
               EP = 1
               U_VELO(IAXIS:KAXIS) = UVW_EP(IAXIS:KAXIS,EP)
               VELN = 0._EB
               SRGH = 0._EB
               IF( CUT_FACE(ICF)%INT_INBFC(1,IFACE)== IBM_FTYPE_CFINB) THEN
                  ICF1 = CUT_FACE(ICF)%INT_INBFC(2,IFACE)
                  ICF2 = CUT_FACE(ICF)%INT_INBFC(3,IFACE)
                  ICFA = CUT_FACE(ICF1)%CFACE_INDEX(ICF2)
                  IF (ICFA>0) THEN
                     VELN = -CFACE(ICFA)%ONE_D%U_NORMAL
                     SRGH = SURFACE(CFACE(ICFA)%SURF_INDEX)%ROUGHNESS
                  ENDIF
               ENDIF
               NN(IAXIS:KAXIS)     = CUT_FACE(ICF)%INT_NOUT(IAXIS:KAXIS,IFACE)
               TT=0._EB; SS=0._EB; U_NORM=0._EB; U_ORTH=0._EB; U_STRM=0._EB
               IF (NORM2(NN) > TWO_EPSILON_EB) THEN
                  XYZ_PP(IAXIS:KAXIS) = CUT_FACE(ICF)%INT_XYZBF(IAXIS:KAXIS,IFACE)
                  U_SURF(IAXIS:KAXIS) = 2._EB*XYZ_PP(IAXIS) + 3._EB*XYZ_PP(JAXIS) + 4._EB*XYZ_PP(KAXIS)
                  U_RELA(IAXIS:KAXIS) = U_VELO(IAXIS:KAXIS)-U_SURF(IAXIS:KAXIS)
                  ! Gives local velocity components U_STRM , U_ORTH , U_NORM
                  ! in terms of unit vectors SS,TT,NN:
                  CALL GET_LOCAL_VELOCITY(U_RELA,NN,TT,SS,U_NORM,U_ORTH,U_STRM)

                  ! Apply wall model to define streamwise velocity at interpolation point:
                  DXN_STRM =CUT_FACE(ICF)%INT_XN(EP,IFACE) ! EP Position from Boundary in NOUT direction
                  DXN_STRM2=CUT_FACE(ICF)%INT_XN(0,IFACE)  ! Interp point position from Boundary in NOUT dir.
                                                           ! Note if this is a -ve number (i.e. Cartesian Faces),
                                                           ! Linear velocity variation should be used.
                  U_NORM2 = DXN_STRM2/DXN_STRM*U_NORM
                  IF(DXN_STRM2 < 0._EB  .OR. IFACE==0) THEN
                     ! Linear variation:
                     U_STRM2 = DXN_STRM2/DXN_STRM*U_STRM
                  ELSE
                     X1F= MESHES(NM)%CUT_FACE(ICF)%XYZCEN(X1AXIS,IFACE)
                     IDX= 1._EB/ ( MESHES(NM)%CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE) - &
                                   MESHES(NM)%CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE) )
                     CCM1= IDX*(MESHES(NM)%CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE)-X1F)
                     CCP1= IDX*(X1F-MESHES(NM)%CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE))
                     ! For NU use interpolation of values on neighboring cut-cells:
                     TMPV(-1:0) = -1._EB; RHOV(-1:0) = 0._EB
                     DO ISIDE=-1,0
                        ZZ_GET = 0._EB
                        SELECT CASE(CUT_FACE(ICF)%CELL_LIST(1,ISIDE+2,IFACE))
                        CASE(IBM_FTYPE_CFGAS) ! Cut-cell -> use Temperature value from CUT_CELL data struct:
                           ICC = CUT_FACE(ICF)%CELL_LIST(2,ISIDE+2,IFACE)
                           JCC = CUT_FACE(ICF)%CELL_LIST(3,ISIDE+2,IFACE)
                           TMPV(ISIDE) = CUT_CELL(ICC)%TMP(JCC)
                           ZZ_GET(1:N_TRACKED_SPECIES) =  CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC)
                           RHOV(ISIDE) = CUT_CELL(ICC)%RHO(JCC)
                        END SELECT
                        CALL GET_VISCOSITY(ZZ_GET,MUV(ISIDE),TMPV(ISIDE))
                     ENDDO
                     MU_FACE = CCM1* MUV(-1) + CCP1* MUV(0)
                     RHO_FACE= CCM1*RHOV(-1) + CCP1*RHOV(0)
                     NU      = MU_FACE/RHO_FACE
                     CALL WALL_MODEL(SLIP_FACTOR,U_TAU,Y_PLUS,NU,SRGH,DXN_STRM,U_STRM,DXN_STRM2,U_STRM2,DUSDN_FP)
                  ENDIF
               ENDIF
               ! Velocity U_ORTH is zero by construction.
               VAL_CC = U_NORM2*NN(X1AXIS) + U_STRM2*SS(X1AXIS) + U_SURF(X1AXIS)
            ENDIF

            VAL_CC_ANN = 2._EB*XYZ(IAXIS) + 3._EB*XYZ(JAXIS) + 4._EB*XYZ(KAXIS)
            L1_DIFF_CUT_FACE = L1_DIFF_CUT_FACE + ABS(VAL_CC-VAL_CC_ANN)
            ! Now field derivatives:
            L1_DIFF_CUT_FACE_UDX = L1_DIFF_CUT_FACE_UDX + ABS(2._EB-DUVW_EP(IAXIS,IAXIS,EP))
            L1_DIFF_CUT_FACE_UDY = L1_DIFF_CUT_FACE_UDY + ABS(3._EB-DUVW_EP(JAXIS,IAXIS,EP))
            L1_DIFF_CUT_FACE_UDZ = L1_DIFF_CUT_FACE_UDZ + ABS(4._EB-DUVW_EP(KAXIS,IAXIS,EP))

            L1_DIFF_CUT_FACE_VDX = L1_DIFF_CUT_FACE_VDX + ABS(2._EB-DUVW_EP(IAXIS,JAXIS,EP))
            L1_DIFF_CUT_FACE_VDY = L1_DIFF_CUT_FACE_VDY + ABS(3._EB-DUVW_EP(JAXIS,JAXIS,EP))
            L1_DIFF_CUT_FACE_VDZ = L1_DIFF_CUT_FACE_VDZ + ABS(4._EB-DUVW_EP(KAXIS,JAXIS,EP))

            L1_DIFF_CUT_FACE_WDX = L1_DIFF_CUT_FACE_WDX + ABS(2._EB-DUVW_EP(IAXIS,KAXIS,EP))
            L1_DIFF_CUT_FACE_WDY = L1_DIFF_CUT_FACE_WDY + ABS(3._EB-DUVW_EP(JAXIS,KAXIS,EP))
            L1_DIFF_CUT_FACE_WDZ = L1_DIFF_CUT_FACE_WDZ + ABS(4._EB-DUVW_EP(KAXIS,KAXIS,EP))

            NP_CUTFACE       = NP_CUTFACE + 1
         ENDDO
      ENDDO ICF_LOOP

   ENDIF

   ! Finally CUT_CELL centroids:
   IF (DO_CUT_CELL) THEN
      VIND = 0
      ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         NCELL  = CUT_CELL(ICC)%NCELL
         I      = CUT_CELL(ICC)%IJK(IAXIS)
         J      = CUT_CELL(ICC)%IJK(JAXIS)
         K      = CUT_CELL(ICC)%IJK(KAXIS)
         DO ICELL=0,NCELL
            VAL_EP  = 0._EB
            DO EP=1,INT_N_EXT_PTS  ! External point for cell ICELL
               INT_NPE_LO = CUT_CELL(ICC)%INT_NPE(LOW_IND,VIND,EP,ICELL)
               INT_NPE_HI = CUT_CELL(ICC)%INT_NPE(HIGH_IND,VIND,EP,ICELL)
               DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                  VAL_EP  = VAL_EP  + CUT_CELL(ICC)%INT_COEF(INPE)* &
                                      CUT_CELL(ICC)%INT_CCVARS(INT_H_IND,INPE)
               ENDDO
            ENDDO

            XYZ_PP(IAXIS:KAXIS) = CUT_CELL(ICC)%INT_XYZBF(IAXIS:KAXIS,ICELL)
            VAL_BP = 2._EB*XYZ_PP(IAXIS) + 3._EB*XYZ_PP(JAXIS) + 4._EB*XYZ_PP(KAXIS)

            COEF_EP = 0._EB
            IF (ABS(CUT_CELL(ICC)%INT_XN(1,ICELL)) > TWO_EPSILON_EB) &
            COEF_EP = CUT_CELL(ICC)%INT_XN(0,ICELL)/CUT_CELL(ICC)%INT_XN(1,ICELL)
            COEF_BP = 1._EB - COEF_EP
            VAL_CC    = COEF_BP*VAL_BP + COEF_EP*VAL_EP

            IF (ICELL==0) THEN
               XYZ(IAXIS:KAXIS) = (/ XC(I), YC(J), ZC(K) /)
            ELSE
               XYZ(IAXIS:KAXIS) = CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,ICELL)
            ENDIF
            VAL_CC_ANN = 2._EB*XYZ(IAXIS) + 3._EB*XYZ(JAXIS) + 4._EB*XYZ(KAXIS)

            L1_DIFF_CUTCELL = L1_DIFF_CUTCELL + ABS(VAL_CC-VAL_CC_ANN)
            NP_CUTCELL      = NP_CUTCELL + 1

         ENDDO
      ENDDO ICC_LOOP
   ENDIF

ENDDO MESH_LOOP

! Write output:
CHECK_LOOP : DO IPROC=0,N_MPI_PROCESSES-1
   CALL MPI_BARRIER(MPI_COMM_WORLD,IERR)
   IF(MY_RANK/=IPROC) CYCLE
   WRITE(LU_OUTPUT,*) ' '
   WRITE(LU_OUTPUT,*) IPROC,'CUT_FACE interp pts=',NP_CUTFACE,', L1_DIFF_INTRP=',L1_DIFF_CUT_FACE
   WRITE(LU_OUTPUT,*) IPROC,'CUT_FACE L1_DIFF_CUT_FACE_UDX,Y,Z=',L1_DIFF_CUT_FACE_UDX,L1_DIFF_CUT_FACE_UDY,&
   L1_DIFF_CUT_FACE_UDZ
   WRITE(LU_OUTPUT,*) IPROC,'CUT_FACE L1_DIFF_CUT_FACE_VDX,Y,Z=',L1_DIFF_CUT_FACE_VDX,L1_DIFF_CUT_FACE_VDY,&
   L1_DIFF_CUT_FACE_VDZ
   WRITE(LU_OUTPUT,*) IPROC,'CUT_FACE L1_DIFF_CUT_FACE_WDX,Y,Z=',L1_DIFF_CUT_FACE_WDX,L1_DIFF_CUT_FACE_WDY,&
   L1_DIFF_CUT_FACE_WDZ
   WRITE(LU_OUTPUT,*) IPROC,'CUT_CELL interp pts=',NP_CUTCELL,', L1_DIFF_INTRP=',L1_DIFF_CUTCELL
ENDDO CHECK_LOOP
IF(MY_RANK==0) WRITE(LU_OUTPUT,*) ' '

! Stop flag for CALL STOP_CHECK(1).
STOP_STATUS = SETUP_ONLY_STOP

RETURN
END SUBROUTINE LINEARFIELDS_INTERP_TEST

! ------------------------------ LINEARFIELDS_INIT -----------------------------

SUBROUTINE LINEARFIELDS_INIT(NM)

INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER :: I,J,K

IF (EVACUATION_ONLY(NM)) RETURN
CALL POINT_TO_MESH(NM)

! Face centered fields, stored in fields U, V ,W:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=0,IBAR
         U(I,J,K) = 2._EB*X(I) + 3._EB*YC(J) + 4._EB*ZC(K)
      ENDDO
   ENDDO
ENDDO
DO K=1,KBAR
   DO J=0,JBAR
      DO I=1,IBAR
         V(I,J,K) = 2._EB*XC(I) + 3._EB*Y(J) + 4._EB*ZC(K)
      ENDDO
   ENDDO
ENDDO
DO K=0,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         W(I,J,K) = 2._EB*XC(I) + 3._EB*YC(J) + 4._EB*Z(K)
      ENDDO
   ENDDO
ENDDO

! Cell centered field, stored in H:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         H(I,J,K)  = 2._EB*XC(I) + 3._EB*YC(J) + 4._EB*ZC(K)
         HS(I,J,K) = H(I,J,K)
      ENDDO
   ENDDO
ENDDO

RETURN

END SUBROUTINE LINEARFIELDS_INIT


! --------------------------- GET_CRTCFCC_INT_STENCILS -----------------------------

SUBROUTINE GET_CRTCFCC_INT_STENCILS

USE GEOMETRY_FUNCTIONS, ONLY : SEARCH_OTHER_MESHES

! Local variables:
INTEGER :: NM
INTEGER :: IRC,X1AXIS,X2AXIS,X3AXIS
INTEGER, ALLOCATABLE, DIMENSION(:,:,:,:)   :: IJKCELL
INTEGER :: I,J,K,NCELL,ICC,JCC,IJK(MAX_DIM),IFC,ICF,ICF1,ICF2,IFACE,LOWHIGH
INTEGER :: XIAXIS,XJAXIS,XKAXIS
INTEGER :: ISTR, IEND, JSTR, JEND, KSTR, KEND
LOGICAL :: FOUND_POINT, INSEG, FOUNDPT
REAL(EB):: XYZ(MAX_DIM),XYZ_PP(MAX_DIM),XYZ_IP(MAX_DIM),DV(MAX_DIM),NVEC(MAX_DIM)
REAL(EB):: P0(MAX_DIM),P1(MAX_DIM),DIST,DISTANCE,DIR_FCT,NORM_DV,LASTDOTNVEC,DOTNVEC
INTEGER :: IND_CC(IAXIS:KAXIS+1),FOUND_INBFC(1:3), BODTRI(1:2)
INTEGER :: CCFC,NFC_CC,ICFC,INBFC,INBFC_LOC,IFCPT,IFCPT_LOC,IBOD,IWSEL,ICELL
INTEGER, PARAMETER :: ADDVEC(1:2,1:4) = RESHAPE( (/1,0,-1,0,0,1,0,-1/), (/2,4/) )
INTEGER :: TESTVAR

INTEGER :: IW,II,JJ,KK,IGC
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC

REAL(EB) :: MIN_DIST_VEL

! OMESH related arrays:
INTEGER, ALLOCATABLE, DIMENSION(:,:,:,:,:) :: IJKFACE2
INTEGER :: IIO,JJO,KKO,NOM
LOGICAL :: FLGX,FLGY,FLGZ,INNM

INTEGER, ALLOCATABLE, DIMENSION(:) :: IIO_FC_R_AUX,JJO_FC_R_AUX,KKO_FC_R_AUX,AXS_FC_R_AUX
INTEGER, ALLOCATABLE, DIMENSION(:) :: IIO_CC_R_AUX,JJO_CC_R_AUX,KKO_CC_R_AUX
INTEGER :: SIZE_REC

INTEGER, PARAMETER :: DELTA_FC = 200

INTEGER, PARAMETER :: OZPOS=0, ICPOS=1, JCPOS=2, IFPOS=3, IWPOS=4

INTEGER :: VIND,EP,INPE,INT_NPE_LO,INT_NPE_HI,NPE_LIST_START,NPE_LIST_COUNT,SZ_1,SZ_2,NPE_COUNT,IEDGE
INTEGER,  ALLOCATABLE, DIMENSION(:,:,:,:) :: INT_NPE
INTEGER,  ALLOCATABLE, DIMENSION(:,:)     :: INT_IJK, INT_NOMIND
REAL(EB), ALLOCATABLE, DIMENSION(:)       :: INT_COEF
REAL(EB), ALLOCATABLE, DIMENSION(:,:)     :: INT_NOUT, INT_DCOEF
REAL(EB) :: DELN,INT_XN(0:INT_N_EXT_PTS),INT_CN(0:INT_N_EXT_PTS)
INTEGER, ALLOCATABLE, DIMENSION(:,:) :: INT_IJK_AUX
REAL(EB),ALLOCATABLE, DIMENSION(:)   :: INT_COEF_AUX
INTEGER :: N_CVAR_START, N_CVAR_COUNT, N_FVAR_START, N_FVAR_COUNT
LOGICAL, ALLOCATABLE, DIMENSION(:) :: EP_TAG

INTEGER, PARAMETER :: IADD(IAXIS:KAXIS,IAXIS:KAXIS) = RESHAPE( (/ 0,1,1,1,0,1,1,1,0 /), (/ MAX_DIM, MAX_DIM /))

LOGICAL, PARAMETER :: FACE_MASK = .TRUE.

INTEGER :: IS,I_SGN,ICD,ICD_SGN,IIF,JJF,KKF,FAXIS,IEC,IE,SKIP_FCT,IEP,JEP,KEP,INDS(1:2,IAXIS:KAXIS)
REAL(EB):: DXX(2),AREA_CF,XB_IB,DEL_EP,DEL_IBEDGE

REAL(EB) CPUTIME,CPUTIME_START,CPUTIME_START_LOOP
CHARACTER(100) :: MSEGS_FILE
INTEGER :: ECOUNT

! Total number of cell centered variables to be exchanges into external normal probe points of CFACES.
N_INT_CVARS = INT_P_IND + N_TRACKED_SPECIES

! Total number of cell centered variables to be exchanged in cut-cell interpolation:
N_INT_CCVARS= INT_WCEN_IND

IF(GET_CUTCELLS_VERBOSE) THEN
   WRITE(LU_SETCC,*) ' '; WRITE(LU_SETCC,'(A)') ' 5. In GET_CRTCFCC_INT_STENCILS, tasks to define IBM stencils:'
   CALL CPU_TIME(CPUTIME_START)
   CPUTIME_START_LOOP = CPUTIME_START
   WRITE(LU_SETCC,'(A)',advance='no') ' - Into First Mesh Loop, various defintions..'
ENDIF

! First fill IJK of cut-cells for CUT_FACE and IBM_RCFACE_VEL, in field CELL_LIST:
! Meshes Loop:
MESHES_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! Mesh sizes:
   NXB=IBAR
   NYB=JBAR
   NZB=KBAR

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.
   ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
   IHI_CELL = IHI_FACE ! Last internal cell index.
   ISTR     = ILO_FACE - NGUARD    ! Allocation start x arrays.
   IEND     = IHI_FACE + NGUARD    ! Allocation end x arrays.

   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.
   JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
   JHI_CELL = JHI_FACE ! Last internal cell index.
   JSTR     = JLO_FACE - NGUARD    ! Allocation start y arrays.
   JEND     = JHI_FACE + NGUARD    ! Allocation end y arrays.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.
   KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
   KHI_CELL = KHI_FACE ! Last internal cell index.
   KSTR     = KLO_FACE - NGUARD    ! Allocation start z arrays.
   KEND     = KHI_FACE + NGUARD    ! Allocation end z arrays.

   ! Initialize IBM_FFNF to IBM_FGSC, this is to discard from the onset faces that can not be used in interpolation
   ! stencils (i.e. not fluid points). Faces allowed for interpolation stencils must be type IBM_GASPHASE:
   FCVAR(:,:,:,IBM_FFNF,IAXIS:KAXIS) = FCVAR(:,:,:,IBM_FGSC,IAXIS:KAXIS)
   IF ( MESHES(NM)%N_CUTCELL_MESH == 0 ) CYCLE MESHES_LOOP

   ! Now loop cut-cells:
   IRC = 0;
   CUT_CELL_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH+MESHES(NM)%N_GCCUTCELL_MESH
      NCELL = CUT_CELL(ICC)%NCELL
      IJK(IAXIS:KAXIS) = CUT_CELL(ICC)%IJK(IAXIS:KAXIS)
      DO JCC=1,NCELL
         ! Loop faces and test:
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! Which face ?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            SELECT CASE(CUT_CELL(ICC)%FACE_LIST(1,IFACE))

            ! If face type in face_list is 0 i.e. regular GASPHASE connecting one or more cut-cells, nothing to do.
            CASE(IBM_FTYPE_RGGAS)
            CASE(IBM_FTYPE_CFGAS) ! GASPHASE cut-face:

               ICF1    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
               ICF2    = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
               IF (LOWHIGH == LOW_IND) THEN ! Cut-face on low side of cut-cell:
                  CUT_FACE(ICF1)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND,ICF2) = &
                                      (/ IBM_FTYPE_CFGAS,     ICC,     JCC,     IFC  /)
                                      !  Cut-cell   CUT_CELL(icc),CCELEM(jcc,:) is cut vol.
               ELSE ! HIGH
                  CUT_FACE(ICF1)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND,ICF2) = &
                                      (/ IBM_FTYPE_CFGAS,     ICC,     JCC,     IFC  /)
                                      !  Cut-cell   CUT_CELL(icc),CCELEM(jcc,:) is cut vol.
               ENDIF

            CASE(IBM_FTYPE_CFINB) ! INBOUNDARY cut-face:

                ICF1    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
                ICF2    = CUT_CELL(ICC)%FACE_LIST(5,IFACE)
                ! We add the cut-cell related info in LOW_IND
                CUT_FACE(ICF1)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND,ICF2) = &
                                    (/ IBM_FTYPE_CFGAS,     ICC,     JCC,     IFC  /)
                                    !  Cut-cell   CUT_CELL(icc),CCELEM(jcc,:) is cut vol.

            END SELECT
         ENDDO
      ENDDO
   ENDDO CUT_CELL_LOOP
ENDDO MESHES_LOOP

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START_LOOP,' sec.'
   WRITE(LU_SETCC,'(A)',advance='no') &
   ' - Into Second Mesh Loop: definition of Interpolation stencils for cut-cells and faces..'
   CALL CPU_TIME(CPUTIME_START_LOOP)
ENDIF

! Here Guardcell exchange of MESHES(NM)%FCVAR(INFACE,JNFACE,KNFACE,IBM_FFNF,X1AXIS),
!                            MESHES(NM)%CCVAR(I,J,K,IBM_CCNC):
! No need to do this, as IBM_FFNF, IBM_CCNC have been populated in the guard-cell region.
!!! ---

! Case of periodic test 103, return. No IBM interpolation needed as there are no immersed Bodies:
IF(PERIODIC_TEST==103 .OR. PERIODIC_TEST==11 .OR. PERIODIC_TEST==7) RETURN

! Then, second mesh loop:
IF( ASSOCIATED(X1FACEP)) NULLIFY(X1FACEP)
IF( ASSOCIATED(X2FACEP)) NULLIFY(X2FACEP)
IF( ASSOCIATED(X3FACEP)) NULLIFY(X3FACEP)
IF( ASSOCIATED(X2CELLP)) NULLIFY(X2CELLP)
IF( ASSOCIATED(X3CELLP)) NULLIFY(X3CELLP)
MESHES_LOOP2 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! Mesh sizes:
   NXB=IBAR
   NYB=JBAR
   NZB=KBAR

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.
   ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
   IHI_CELL = IHI_FACE ! Last internal cell index.
   ISTR     = ILO_FACE - NGUARD    ! Allocation start x arrays.
   IEND     = IHI_FACE + NGUARD    ! Allocation end x arrays.

   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.
   JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
   JHI_CELL = JHI_FACE ! Last internal cell index.
   JSTR     = JLO_FACE - NGUARD    ! Allocation start y arrays.
   JEND     = JHI_FACE + NGUARD    ! Allocation end y arrays.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.
   KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
   KHI_CELL = KHI_FACE ! Last internal cell index.
   KSTR     = KLO_FACE - NGUARD    ! Allocation start z arrays.
   KEND     = KHI_FACE + NGUARD    ! Allocation end z arrays.

   ! Define grid arrays for this mesh:
   ! Populate position and cell size arrays: Uniform grid implementation.
   ! X direction:
   ALLOCATE(DXCELL(ISTR:IEND)); DXCELL(ILO_CELL-1:IHI_CELL+1) = DX(ILO_CELL-1:IHI_CELL+1)
   DO IGC=2,NGUARD
      DXCELL(ILO_CELL-IGC)=DXCELL(ILO_CELL-IGC+1)
      DXCELL(IHI_CELL+IGC)=DXCELL(IHI_CELL+IGC-1)
   ENDDO
   ALLOCATE(DXFACE(ISTR:IEND)); DXFACE(ILO_FACE:IHI_FACE)= DXN(ILO_FACE:IHI_FACE)
   DO IGC=1,NGUARD
      DXFACE(ILO_FACE-IGC)=DXFACE(ILO_FACE-IGC+1)
      DXFACE(IHI_FACE+IGC)=DXFACE(ILO_FACE+IGC-1)
   ENDDO
   ALLOCATE(XCELL(ISTR:IEND));  XCELL = 1._EB/GEOMEPS ! Initialize huge.
   XCELL(ILO_CELL-1:IHI_CELL+1) = XC(ILO_CELL-1:IHI_CELL+1)
   DO IGC=2,NGUARD
      XCELL(ILO_CELL-IGC)=XCELL(ILO_CELL-IGC+1)-DXFACE(ILO_FACE-IGC+1)
      XCELL(IHI_CELL+IGC)=XCELL(IHI_CELL+IGC-1)+DXFACE(IHI_FACE+IGC-1)
   ENDDO
   ALLOCATE(XFACE(ISTR:IEND));  XFACE = 1._EB/GEOMEPS ! Initialize huge.
   XFACE(ILO_FACE:IHI_FACE) = X(ILO_FACE:IHI_FACE)
   DO IGC=1,NGUARD
      XFACE(ILO_FACE-IGC)=XFACE(ILO_FACE-IGC+1)-DXCELL(ILO_CELL-IGC)
      XFACE(IHI_FACE+IGC)=XFACE(IHI_FACE+IGC-1)+DXCELL(IHI_CELL+IGC)
   ENDDO

   ! Y direction:
   ALLOCATE(DYCELL(JSTR:JEND)); DYCELL(JLO_CELL-1:JHI_CELL+1)= DY(JLO_CELL-1:JHI_CELL+1)
   DO IGC=2,NGUARD
      DYCELL(JLO_CELL-IGC)=DYCELL(JLO_CELL-IGC+1)
      DYCELL(JHI_CELL+IGC)=DYCELL(JHI_CELL+IGC-1)
   ENDDO
   ALLOCATE(DYFACE(JSTR:JEND)); DYFACE(JLO_FACE:JHI_FACE)= DYN(JLO_FACE:JHI_FACE)
   DO IGC=1,NGUARD
      DYFACE(JLO_FACE-IGC)=DYFACE(JLO_FACE-IGC+1)
      DYFACE(JHI_FACE+IGC)=DYFACE(JHI_FACE+IGC-1)
   ENDDO
   ALLOCATE(YCELL(JSTR:JEND));  YCELL = 1._EB/GEOMEPS ! Initialize huge.
   YCELL(JLO_CELL-1:JHI_CELL+1) = YC(JLO_CELL-1:JHI_CELL+1)
   DO IGC=2,NGUARD
      YCELL(JLO_CELL-IGC)=YCELL(JLO_CELL-IGC+1)-DYFACE(JLO_FACE-IGC+1)
      YCELL(JHI_CELL+IGC)=YCELL(JHI_CELL+IGC-1)+DYFACE(JHI_FACE+IGC-1)
   ENDDO
   ALLOCATE(YFACE(JSTR:JEND));  YFACE = 1._EB/GEOMEPS ! Initialize huge.
   YFACE(JLO_FACE:JHI_FACE) = Y(JLO_FACE:JHI_FACE)
   DO IGC=1,NGUARD
      YFACE(JLO_FACE-IGC)=YFACE(JLO_FACE-IGC+1)-DYCELL(JLO_CELL-IGC)
      YFACE(JHI_FACE+IGC)=YFACE(JHI_FACE+IGC-1)+DYCELL(JHI_CELL+IGC)
   ENDDO

   ! Z direction:
   ALLOCATE(DZCELL(KSTR:KEND)); DZCELL(KLO_CELL-1:KHI_CELL+1)= DZ(KLO_CELL-1:KHI_CELL+1)
   DO IGC=2,NGUARD
      DZCELL(KLO_CELL-IGC)=DZCELL(KLO_CELL-IGC+1)
      DZCELL(KHI_CELL+IGC)=DZCELL(KHI_CELL+IGC-1)
   ENDDO
   ALLOCATE(DZFACE(KSTR:KEND)); DZFACE(KLO_FACE:KHI_FACE)= DZN(KLO_FACE:KHI_FACE)
   DO IGC=1,NGUARD
      DZFACE(KLO_FACE-IGC)=DZFACE(KLO_FACE-IGC+1)
      DZFACE(KHI_FACE+IGC)=DZFACE(KHI_FACE+IGC-1)
   ENDDO
   ALLOCATE(ZCELL(KSTR:KEND));  ZCELL = 1._EB/GEOMEPS ! Initialize huge.
   ZCELL(KLO_CELL-1:KHI_CELL+1) = ZC(KLO_CELL-1:KHI_CELL+1)
   DO IGC=2,NGUARD
      ZCELL(KLO_CELL-IGC)=ZCELL(KLO_CELL-IGC+1)-DZFACE(KLO_FACE-IGC+1)
      ZCELL(KHI_CELL+IGC)=ZCELL(KHI_CELL+IGC-1)+DZFACE(KHI_FACE+IGC-1)
   ENDDO
   ALLOCATE(ZFACE(KSTR:KEND));  ZFACE = 1._EB/GEOMEPS ! Initialize huge.
   ZFACE(KLO_FACE:KHI_FACE) = Z(KLO_FACE:KHI_FACE)
   DO IGC=1,NGUARD
      ZFACE(KLO_FACE-IGC)=ZFACE(KLO_FACE-IGC+1)-DZCELL(KLO_CELL-IGC)
      ZFACE(KHI_FACE+IGC)=ZFACE(KHI_FACE+IGC-1)+DZCELL(KHI_CELL+IGC)
   ENDDO

   ! 1.:
   ! Loop by CUT_FACE, define interpolation stencils in Cartesian and cut-face
   ! centroids using the corresponding cells INBOUNDARY cut-faces and external
   ! face centered fluid points:
   CUT_FACE_LOOP : DO ICF=1,MESHES(NM)%N_CUTFACE_MESH

      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      IJK(IAXIS:KAXIS) = (/ I, J, K /)

      CUTFACE_STATUS_IF : IF (CUT_FACE(ICF)%STATUS == IBM_GASPHASE) THEN

         X1AXIS = CUT_FACE(ICF)%IJK(KAXIS+1)

         ! First, underlying cartesian face centroid:
         ! Centroid location in 3D:
         SELECT CASE (X1AXIS)
         CASE(IAXIS)
             XYZ(IAXIS:KAXIS) = (/ XFACE(I), YCELL(J), ZCELL(K) /)
             MIN_DIST_VEL = DIST_THRES*MIN(DXFACE(I),DYCELL(J),DZCELL(K))
             ! x2, x3 axes:
             X2AXIS = JAXIS; X3AXIS = KAXIS
             X1LO_FACE = ILO_FACE-CCGUARD; X1LO_CELL = ILO_CELL-CCGUARD
             X1HI_FACE = IHI_FACE+CCGUARD; X1HI_CELL = IHI_CELL+CCGUARD
             X2LO_FACE = JLO_FACE-CCGUARD; X2LO_CELL = JLO_CELL-CCGUARD
             X2HI_FACE = JHI_FACE+CCGUARD; X2HI_CELL = JHI_CELL+CCGUARD
             X3LO_FACE = KLO_FACE-CCGUARD; X3LO_CELL = KLO_CELL-CCGUARD
             X3HI_FACE = KHI_FACE+CCGUARD; X3HI_CELL = KHI_CELL+CCGUARD
             ! location in I,J,K od x2,x2,x3 axes:
             XIAXIS = IAXIS; XJAXIS = JAXIS; XKAXIS = KAXIS
             ! Face coordinates in x1,x2,x3 axes:
             X1FACEP => XFACE;
             X2FACEP => YFACE; X2CELLP => YCELL
             X3FACEP => ZFACE; X3CELLP => ZCELL
         CASE(JAXIS)
             XYZ(IAXIS:KAXIS) = (/ XCELL(I), YFACE(J), ZCELL(K) /)
             MIN_DIST_VEL = DIST_THRES*MIN(DXCELL(I),DYFACE(J),DZCELL(K))
             ! x2, x3 axes:
             X2AXIS = KAXIS;  X3AXIS = IAXIS
             X1LO_FACE = JLO_FACE-CCGUARD; X1LO_CELL = JLO_CELL-CCGUARD
             X1HI_FACE = JHI_FACE+CCGUARD; X1HI_CELL = JHI_CELL+CCGUARD
             X2LO_FACE = KLO_FACE-CCGUARD; X2LO_CELL = KLO_CELL-CCGUARD
             X2HI_FACE = KHI_FACE+CCGUARD; X2HI_CELL = KHI_CELL+CCGUARD
             X3LO_FACE = ILO_FACE-CCGUARD; X3LO_CELL = ILO_CELL-CCGUARD
             X3HI_FACE = IHI_FACE+CCGUARD; X3HI_CELL = IHI_CELL+CCGUARD
             ! location in I,J,K od x2,x2,x3 axes:
             XIAXIS = KAXIS; XJAXIS = IAXIS; XKAXIS = JAXIS
             ! Face coordinates in x1,x2,x3 axes:
             X1FACEP => YFACE;
             X2FACEP => ZFACE; X2CELLP => ZCELL
             X3FACEP => XFACE; X3CELLP => XCELL
         CASE(KAXIS)
             XYZ(IAXIS:KAXIS) = (/ XCELL(I), YCELL(J), ZFACE(K) /)
             MIN_DIST_VEL = DIST_THRES*MIN(DXCELL(I),DYCELL(J),DZFACE(K))
             ! x2, x3 axes:
             X2AXIS = IAXIS;  X3AXIS = JAXIS
             X1LO_FACE = KLO_FACE-CCGUARD; X1LO_CELL = KLO_CELL-CCGUARD
             X1HI_FACE = KHI_FACE+CCGUARD; X1HI_CELL = KHI_CELL+CCGUARD
             X2LO_FACE = ILO_FACE-CCGUARD; X2LO_CELL = ILO_CELL-CCGUARD
             X2HI_FACE = IHI_FACE+CCGUARD; X2HI_CELL = IHI_CELL+CCGUARD
             X3LO_FACE = JLO_FACE-CCGUARD; X3LO_CELL = JLO_CELL-CCGUARD
             X3HI_FACE = JHI_FACE+CCGUARD; X3HI_CELL = JHI_CELL+CCGUARD
             ! location in I,J,K od x2,x2,x3 axes:
             XIAXIS = JAXIS; XJAXIS = KAXIS; XKAXIS = IAXIS
             ! Face coordinates in x1,x2,x3 axes:
             X1FACEP => ZFACE;
             X2FACEP => XFACE; X2CELLP => XCELL
             X3FACEP => YFACE; X3CELLP => YCELL
         END SELECT

         NPE_LIST_START = 0
         ALLOCATE(INT_NPE(LOW_IND:HIGH_IND,IAXIS:KAXIS,1:INT_N_EXT_PTS,0:CUT_FACE(ICF)%NFACE), &
                  INT_IJK(IAXIS:KAXIS,(CUT_FACE(ICF)%NFACE+1)*DELTA_INT),                      &
                  INT_COEF((CUT_FACE(ICF)%NFACE+1)*DELTA_INT),INT_NOUT(IAXIS:KAXIS,0:CUT_FACE(ICF)%NFACE))
         DO IFACE=0,CUT_FACE(ICF)%NFACE

            ! do cut-face centroid for IFACE > 0:
            IF (IFACE > 0) XYZ(IAXIS:KAXIS) = CUT_FACE(ICF)%XYZCEN(IAXIS:KAXIS,IFACE)

            ! Initialize closest inboundary point data:
            DISTANCE            = 1._EB / GEOMEPS
            LASTDOTNVEC         =-1._EB / GEOMEPS
            FOUND_POINT         = .FALSE.
            XYZ_PP(IAXIS:KAXIS) = 0._EB
            FOUND_INBFC(1:3)    = 0

            ! Now LOW side list of INBOUNDARY cut faces, search for closest point to xyz:
            DO LOWHIGH=LOW_IND,HIGH_IND

               DO ICF2=1,CUT_FACE(ICF)%NFACE

                  IND_CC(IAXIS:KAXIS+1) = CUT_FACE(ICF)%CELL_LIST(IAXIS:KAXIS+1,LOWHIGH,ICF2)

                  IF (IND_CC(1) == IBM_FTYPE_RGGAS) CYCLE ! Cell regular gasphase

                  ICC = IND_CC(2)
                  JCC = IND_CC(3)

                  ! Find closest point and Inboundary cut-face:
                  NFC_CC = MESHES(NM)%CUT_CELL(ICC)%CCELEM(1,JCC)
                  DO CCFC=1,NFC_CC

                     ICFC = MESHES(NM)%CUT_CELL(ICC)%CCELEM(CCFC+1,JCC)
                     IF ( MESHES(NM)%CUT_CELL(ICC)%FACE_LIST(1,ICFC) /= IBM_FTYPE_CFINB) CYCLE

                     ! Inboundary face number in CUT_FACE:
                     INBFC     = MESHES(NM)%CUT_CELL(ICC)%FACE_LIST(4,ICFC)
                     INBFC_LOC = MESHES(NM)%CUT_CELL(ICC)%FACE_LIST(5,ICFC)

                     CALL GET_CLSPT_INBCF(NM,XYZ,INBFC,INBFC_LOC,XYZ_IP,DIST,FOUNDPT,INSEG)
                     IF (FOUNDPT .AND. ((DIST-DISTANCE) < GEOMEPS)) THEN
                         IF (INSEG) THEN
                             BODTRI(1:2)  = CUT_FACE(INBFC)%BODTRI(1:2,INBFC_LOC)
                             ! normal vector to boundary surface triangle:
                             IBOD    = BODTRI(1)
                             IWSEL   = BODTRI(2)
                             NVEC(IAXIS:KAXIS) = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)
                             DV(IAXIS:KAXIS) = XYZ(IAXIS:KAXIS) - XYZ_IP(IAXIS:KAXIS)
                             NORM_DV = SQRT( DV(IAXIS)**2._EB + DV(JAXIS)**2._EB + DV(KAXIS)**2._EB )
                             IF(NORM_DV > GEOMEPS) THEN ! Point in segment not same as pt to interp to.
                                DV(IAXIS:KAXIS) = (1._EB / NORM_DV) * DV(IAXIS:KAXIS)
                                DOTNVEC = NVEC(IAXIS)*DV(IAXIS) + NVEC(JAXIS)*DV(JAXIS) + NVEC(KAXIS)*DV(KAXIS)
                                IF (DOTNVEC <= LASTDOTNVEC) CYCLE
                                LASTDOTNVEC = DOTNVEC
                             ENDIF
                         ENDIF
                         DISTANCE = DIST
                         XYZ_PP(IAXIS:KAXIS)   = XYZ_IP(IAXIS:KAXIS)
                         FOUND_INBFC(1:3) = (/ IBM_FTYPE_CFINB, INBFC, INBFC_LOC /) ! Inbound cut-face in CUT_FACE.
                         FOUND_POINT = .TRUE.
                     ENDIF

                  ENDDO

                  ! If point not found, all cut-faces boundary of the icc, jcc volume
                  ! are GASPHASE. There must be a SOLID point in the boundary of the
                  ! underlying Cartesian cell. this is the closest point:
                  IF (.NOT.FOUND_POINT) THEN
                      ! Search for for CUT_CELL(icc) vertex points or other solid points:
                      CALL GET_CLOSEPT_CCVT(NM,XYZ,ICC,XYZ_IP,DIST,FOUNDPT,IFCPT,IFCPT_LOC)
                      IF (FOUNDPT .AND. ((DIST-DISTANCE) < GEOMEPS)) THEN
                         DISTANCE = DIST
                         XYZ_PP(IAXIS:KAXIS)   = XYZ_IP(IAXIS:KAXIS)
                         FOUND_INBFC(1:3) = (/ IBM_FTYPE_SVERT, IFCPT, IFCPT_LOC /) ! SOLID vertex in CUT_FACE.
                         FOUND_POINT = .TRUE.
                      ENDIF
                  ENDIF

               ENDDO ! ICF2

            ENDDO ! Loop over LOW side and HIGH side cut-cells of GASPHASE cut-face.

            IF (.NOT.FOUND_POINT .AND. GET_CUTCELLS_VERBOSE) WRITE(LU_ERR,*)'CF: Havent found closest point. ICF, IFACE=',ICF,IFACE

            ! Here test if point in boundary and interpolation point coincide:
            IF (DISTANCE <= MIN_DIST_VEL) THEN
               INT_NOUT(IAXIS:KAXIS,IFACE) = 0._EB
               INT_XN(0:INT_N_EXT_PTS) = 0._EB
               INT_CN(0:INT_N_EXT_PTS) = 0._EB; INT_CN(0) = 1._EB ! Boundary point coefficient:
               DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                  DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                     NPE_LIST_COUNT = 0
                     INT_NPE(LOW_IND,VIND,EP,IFACE)  = NPE_LIST_START
                     INT_NPE(HIGH_IND,VIND,EP,IFACE) = NPE_LIST_COUNT
                     NPE_LIST_START = NPE_LIST_START + NPE_LIST_COUNT
                  ENDDO
               ENDDO

            ELSE
               ! After this loop we have the closest boundary point to xyz and the
               ! cut-face it belongs. We need to use the normal out of the face (or the
               ! vertex to xyz direction to find fluid points on the stencil:
               ! The fluid points are points that lay on the plane outside in the
               ! largest Cartesian component direction of the normal.
               DIR_FCT = 1._EB
               IF (FOUND_INBFC(1) == IBM_FTYPE_CFINB) THEN ! closest point in INBOUNDARY cut-face.
                   BODTRI(1:2) = CUT_FACE(FOUND_INBFC(2))%BODTRI(1:2,FOUND_INBFC(3))
                   ! normal vector to boundary surface triangle:
                   IBOD    = BODTRI(1)
                   IWSEL   = BODTRI(2)
                   NVEC(IAXIS:KAXIS) = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)
                   DV(IAXIS:KAXIS) = XYZ(IAXIS:KAXIS) - XYZ_PP(IAXIS:KAXIS)
                   DOTNVEC = NVEC(IAXIS)*DV(IAXIS) + NVEC(JAXIS)*DV(JAXIS) + NVEC(KAXIS)*DV(KAXIS)

                   IF (DOTNVEC < 0._EB) DIR_FCT = -1._EB ! if normal to triangle has opposite dir change
                                                         ! search direction.
               ENDIF
               !print*, 'DIR_FCT=',DIR_FCT
               !print*, 'XYZ=',XYZ(IAXIS:KAXIS)
               !print*, 'XYZ_PP=',XYZ_PP(IAXIS:KAXIS)
               DV(IAXIS:KAXIS)   = DIR_FCT * ( XYZ(IAXIS:KAXIS) - XYZ_PP(IAXIS:KAXIS) )
               NORM_DV           = SQRT( DV(IAXIS)**2._EB + DV(JAXIS)**2._EB + DV(KAXIS)**2._EB )
               DV(IAXIS:KAXIS) = (1._EB / NORM_DV) * DV(IAXIS:KAXIS) ! NOUT

               SELECT CASE (X1AXIS)
               CASE(IAXIS)
                  CALL GET_DELN(1.5015_EB,DELN,DXFACE(I),DYCELL(J),DZCELL(K),NVEC=DV)
               CASE(JAXIS)
                  CALL GET_DELN(1.5015_EB,DELN,DXCELL(I),DYFACE(J),DZCELL(K),NVEC=DV)
               CASE(KAXIS)
                  CALL GET_DELN(1.5015_EB,DELN,DXCELL(I),DYCELL(J),DZFACE(K),NVEC=DV)
               END SELECT

               ! Location of interpolation point XYZ(IAXIS:KAXIS) along the DV direction, origin in
               ! boundary point XYZ_PP(IAXIS:KAXIS):
               INT_NOUT(IAXIS:KAXIS,IFACE) = DV(IAXIS:KAXIS)
               INT_XN(0)               = DIR_FCT * NORM_DV
               INT_XN(1:INT_N_EXT_PTS) = 0._EB
               ! Initialize interpolation coefficients along the normal probe direction DV
               INT_CN(0) = 0._EB; ! Boundary point interpolation coefficient
               INT_CN(1:INT_N_EXT_PTS) = 0._EB;
               DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                  INT_XN(EP) = REAL(EP,EB)*DELN
                  DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point, masked interpolation.
                     CALL GET_INTSTENCILS_EP(FACE_MASK,VIND,XYZ_PP,INT_XN(EP),DV, &
                                             NPE_LIST_START,NPE_LIST_COUNT,INT_IJK,INT_COEF)
                     ! Start position for interpolation stencil related to velocity component VIND, of external
                     ! point EP related to cut-face IFACE:
                     INT_NPE(LOW_IND,VIND,EP,IFACE)  = NPE_LIST_START
                     ! Number of stencil points on stencil for said velocity component.
                     INT_NPE(HIGH_IND,VIND,EP,IFACE) = NPE_LIST_COUNT
                     NPE_LIST_START = NPE_LIST_START + NPE_LIST_COUNT
                  ENDDO
               ENDDO
            ENDIF

            ! Add coefficients to CUT_FACE fields:
            CUT_FACE(ICF)%INT_XYZBF(IAXIS:KAXIS,IFACE) = XYZ_PP(IAXIS:KAXIS) ! xyz of boundary pt.
            CUT_FACE(ICF)%INT_INBFC(1:3,IFACE)         = FOUND_INBFC(1:3)  ! which INB cut-face bndry pt belongs to.
            CUT_FACE(ICF)%INT_NOUT(IAXIS:KAXIS,IFACE)  = INT_NOUT(IAXIS:KAXIS,IFACE)
            CUT_FACE(ICF)%INT_XN(0:INT_N_EXT_PTS,IFACE)= INT_XN(0:INT_N_EXT_PTS)
            CUT_FACE(ICF)%INT_CN(0:INT_N_EXT_PTS,IFACE)= INT_CN(0:INT_N_EXT_PTS)
            ! If size of CUT_FACE(ICF)%INT_IJK,DIM=2 is less than the size of INT_IJK, reallocate:
            SZ_1 = SIZE(CUT_FACE(ICF)%INT_IJK,DIM=2)
            SZ_2 = SIZE(INT_IJK,DIM=2)
            IF(SZ_2 > SZ_1) THEN
               ALLOCATE(INT_IJK_AUX(IAXIS:KAXIS,SZ_1),INT_COEF_AUX(1:SZ_1))
               INT_IJK_AUX(IAXIS:KAXIS,1:SZ_1)  = CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,1:SZ_1)
               INT_COEF_AUX(1:SZ_1)             = CUT_FACE(ICF)%INT_COEF(1:SZ_1)
               DEALLOCATE(CUT_FACE(ICF)%INT_IJK, CUT_FACE(ICF)%INT_COEF, CUT_FACE(ICF)%INT_DCOEF)
               ALLOCATE(CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,SZ_2)); CUT_FACE(ICF)%INT_IJK = IBM_UNDEFINED
               ALLOCATE(CUT_FACE(ICF)%INT_COEF(1:SZ_2)); CUT_FACE(ICF)%INT_COEF = 0._EB
               ALLOCATE(CUT_FACE(ICF)%INT_DCOEF(IAXIS:KAXIS,1:SZ_2)); CUT_FACE(ICF)%INT_DCOEF = 0._EB
               CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,1:SZ_1)  = INT_IJK_AUX(IAXIS:KAXIS,1:SZ_1)
               CUT_FACE(ICF)%INT_COEF(1:SZ_1)             = INT_COEF_AUX(1:SZ_1)
               DEALLOCATE(INT_IJK_AUX,INT_COEF_AUX)
               DEALLOCATE(CUT_FACE(ICF)%INT_FVARS,CUT_FACE(ICF)%INT_NOMIND)
               ALLOCATE(CUT_FACE(ICF)%INT_FVARS(1:N_INT_FVARS,SZ_2)); CUT_FACE(ICF)%INT_FVARS=0._EB
               ALLOCATE(CUT_FACE(ICF)%INT_NOMIND(LOW_IND:HIGH_IND,SZ_2)); CUT_FACE(ICF)%INT_NOMIND = IBM_UNDEFINED
            ENDIF
            DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
               DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                  INT_NPE_LO = INT_NPE(LOW_IND,VIND,EP,IFACE)
                  INT_NPE_HI = INT_NPE(HIGH_IND,VIND,EP,IFACE)
                  CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE) = INT_NPE_LO
                  CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)= INT_NPE_HI
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,INPE)  = INT_IJK(IAXIS:KAXIS,INPE)
                     CUT_FACE(ICF)%INT_COEF(INPE)             = INT_COEF(INPE)
                  ENDDO
               ENDDO
            ENDDO

         ENDDO ! IFACE loop
         NULLIFY(X1FACEP,X2FACEP,X3FACEP,X2CELLP,X3CELLP)

         DEALLOCATE(INT_NPE,INT_IJK,INT_COEF,INT_NOUT)

      ELSEIF(CUT_FACE(ICF)%STATUS == IBM_INBOUNDARY) THEN ! CUTFACE_STATUS_IF

         ! Here we define interpolation stencils that will be used to populate ONE_D%H_G, TMP_G, RHO_G,
         ! ZZ_G, MU_G, U_TANG and U_VEL, V_VEL, W_VEL, KRES of corresponding CFACES.
         ! These variables are to be used to compute heat transfer, species BCs and to compute stresses and pressure
         ! at the CFACE wall.
         IF(SOLID(CELL_INDEX(I,J,K))) CYCLE

         MIN_DIST_VEL = DIST_THRES*MIN(DXCELL(I),DYCELL(J),DZCELL(K))
         NPE_LIST_START = 0
         ALLOCATE(INT_NPE(LOW_IND:HIGH_IND,0:KAXIS,1:INT_N_EXT_PTS,1:CUT_FACE(ICF)%NFACE), &
                  INT_IJK(IAXIS:KAXIS,(CUT_FACE(ICF)%NFACE+1)*DELTA_INT),                      &
                  INT_COEF((CUT_FACE(ICF)%NFACE+1)*DELTA_INT),INT_NOUT(IAXIS:KAXIS,1:CUT_FACE(ICF)%NFACE))
         ! Fill cell centered stencils first:
         N_CVAR_START = NPE_LIST_START
         DO IFACE=1,CUT_FACE(ICF)%NFACE
            ICF1 = CUT_FACE(ICF)%CFACE_INDEX(IFACE)
            DV(IAXIS:KAXIS) = CFACE(ICF1)%NVEC(IAXIS:KAXIS)
            CALL GET_DELN(1.001_EB,DELN,DXCELL(I),DYCELL(J),DZCELL(K),NVEC=DV,CLOSE_PT=.TRUE.)
            ! Origin in boundary point XYZ_PP(IAXIS:KAXIS):
            XYZ_PP(IAXIS:KAXIS)         = CUT_FACE(ICF)%XYZCEN(IAXIS:KAXIS,IFACE)
            DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
               INT_XN(EP) = REAL(EP,EB)*DELN
               ! First cell centered variables:
               VIND=0
               CALL GET_INTSTENCILS_EP(.FALSE.,VIND,XYZ_PP,INT_XN(EP),DV, &
                                       NPE_LIST_START,NPE_LIST_COUNT,INT_IJK,INT_COEF)
               ! Start position for interpolation stencil related to velocity component VIND, of external
               ! point EP related to cut-face IFACE:
               INT_NPE(LOW_IND,VIND,EP,IFACE)  = NPE_LIST_START
               ! Number of stencil points on stencil for said velocity component.
               INT_NPE(HIGH_IND,VIND,EP,IFACE) = NPE_LIST_COUNT
               NPE_LIST_START = NPE_LIST_START + NPE_LIST_COUNT
            ENDDO
         ENDDO
         ! Number of cell centered stencil points:
         N_CVAR_COUNT = NPE_LIST_START

         ! Now face centered stencils:
         N_FVAR_START = N_CVAR_START + N_CVAR_COUNT
         DO IFACE=1,CUT_FACE(ICF)%NFACE
            ! Origin in boundary point XYZ_PP(IAXIS:KAXIS):
            XYZ_PP(IAXIS:KAXIS)         = CUT_FACE(ICF)%XYZCEN(IAXIS:KAXIS,IFACE)
            FOUND_INBFC(1:3) = (/ IBM_FTYPE_CFINB, ICF, IFACE /)
            ICF1 = CUT_FACE(ICF)%CFACE_INDEX(IFACE)
            DV(IAXIS:KAXIS) = CFACE(ICF1)%NVEC(IAXIS:KAXIS)
            INT_NOUT(IAXIS:KAXIS,IFACE) = DV(IAXIS:KAXIS)
            INT_XN(0:INT_N_EXT_PTS) = 0._EB
            ! Initialize interpolation coefficients along the normal probe direction DV
            INT_CN(0) = 0._EB; ! Boundary point interpolation coefficient
            INT_CN(1:INT_N_EXT_PTS) = 0._EB;
            CALL GET_DELN(1.001_EB,DELN,DXCELL(I),DYCELL(J),DZCELL(K),NVEC=DV,CLOSE_PT=.TRUE.)
            DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
               INT_XN(EP) = REAL(EP,EB)*DELN
               ! Then face variables:
               DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point, masked interpolation.
                  CALL GET_INTSTENCILS_EP(.FALSE.,VIND,XYZ_PP,INT_XN(EP),DV, &
                                          NPE_LIST_START,NPE_LIST_COUNT,INT_IJK,INT_COEF)
                  ! Start position for interpolation stencil related to velocity component VIND, of external
                  ! point EP related to cut-face IFACE:
                  INT_NPE(LOW_IND,VIND,EP,IFACE)  = NPE_LIST_START
                  ! Number of stencil points on stencil for said velocity component.
                  INT_NPE(HIGH_IND,VIND,EP,IFACE) = NPE_LIST_COUNT
                  NPE_LIST_START = NPE_LIST_START + NPE_LIST_COUNT
               ENDDO
            ENDDO
            CUT_FACE(ICF)%INT_XYZBF(IAXIS:KAXIS,IFACE) = XYZ_PP(IAXIS:KAXIS) ! xyz of boundary pt.
            CUT_FACE(ICF)%INT_INBFC(1:3,IFACE)         = FOUND_INBFC(1:3)  ! which INB cut-face boundary pt belongs to.
            CUT_FACE(ICF)%INT_NOUT(IAXIS:KAXIS,IFACE)  = INT_NOUT(IAXIS:KAXIS,IFACE)
            CUT_FACE(ICF)%INT_XN(0:INT_N_EXT_PTS,IFACE)= INT_XN(0:INT_N_EXT_PTS)
            CUT_FACE(ICF)%INT_CN(0:INT_N_EXT_PTS,IFACE)= INT_CN(0:INT_N_EXT_PTS)
         ENDDO
         N_FVAR_COUNT = NPE_LIST_START - N_FVAR_START


         ! Finally Define IJK and interp coeffs for EPs:
         ! If size of CUT_FACE(ICF)%INT_IJK,DIM=2 is less than the size of INT_IJK, reallocate:
         SZ_1 = SIZE(CUT_FACE(ICF)%INT_IJK,DIM=2)
         SZ_2 = SIZE(INT_IJK,DIM=2)
         IF(SZ_2 > SZ_1) THEN
            ALLOCATE(INT_IJK_AUX(IAXIS:KAXIS,1:SZ_1),INT_COEF_AUX(1:SZ_1))
            INT_IJK_AUX(IAXIS:KAXIS,1:SZ_1) = CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,1:SZ_1)
            INT_COEF_AUX(1:SZ_1)            = CUT_FACE(ICF)%INT_COEF(1:SZ_1)
            DEALLOCATE(CUT_FACE(ICF)%INT_IJK, CUT_FACE(ICF)%INT_COEF)
            ALLOCATE(CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,1:SZ_2)); CUT_FACE(ICF)%INT_IJK = IBM_UNDEFINED
            ALLOCATE(CUT_FACE(ICF)%INT_COEF(1:SZ_2)); CUT_FACE(ICF)%INT_COEF = 0._EB
            CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,1:SZ_1) = INT_IJK_AUX(IAXIS:KAXIS,1:SZ_1)
            CUT_FACE(ICF)%INT_COEF(1:SZ_1)            = INT_COEF_AUX(1:SZ_1)
            DEALLOCATE(INT_IJK_AUX,INT_COEF_AUX)
            DEALLOCATE(CUT_FACE(ICF)%INT_NOMIND)
            ALLOCATE(CUT_FACE(ICF)%INT_NOMIND(LOW_IND:HIGH_IND,1:SZ_2)); CUT_FACE(ICF)%INT_NOMIND = IBM_UNDEFINED
         ENDIF
         ! Reallocate INT_CVARS, INT_FVARS:
         IF (ALLOCATED(CUT_FACE(ICF)%INT_CVARS)) DEALLOCATE(CUT_FACE(ICF)%INT_CVARS)
         ALLOCATE(CUT_FACE(ICF)%INT_CVARS(1:N_INT_CVARS,N_CVAR_START+1:N_CVAR_START+N_CVAR_COUNT))
         IF (ALLOCATED(CUT_FACE(ICF)%INT_FVARS)) DEALLOCATE(CUT_FACE(ICF)%INT_FVARS)
         ALLOCATE(CUT_FACE(ICF)%INT_FVARS(1:N_INT_FVARS,N_FVAR_START+1:N_FVAR_START+N_FVAR_COUNT))
         CUT_FACE(ICF)%INT_CVARS=0._EB; CUT_FACE(ICF)%INT_FVARS=0._EB

         ! Finally Define IJK and interp coeffs for EPs:
         DO IFACE=1,CUT_FACE(ICF)%NFACE
            DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
               DO VIND=0,KAXIS ! Centered and face variables for external point EP
                  INT_NPE_LO = INT_NPE(LOW_IND,VIND,EP,IFACE)
                  INT_NPE_HI = INT_NPE(HIGH_IND,VIND,EP,IFACE)
                  CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE) = INT_NPE_LO
                  CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)= INT_NPE_HI
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,INPE) = INT_IJK(IAXIS:KAXIS,INPE)
                     CUT_FACE(ICF)%INT_COEF(INPE)            = INT_COEF(INPE)
                  ENDDO
               ENDDO
            ENDDO
         ENDDO

         DEALLOCATE(INT_NPE,INT_IJK,INT_COEF,INT_NOUT)

      ENDIF CUTFACE_STATUS_IF

   ENDDO CUT_FACE_LOOP

   ! 2.:
   ! Loop by CUT_CELL, define interpolation stencils in Cartesian and cut
   ! cell centroids using the corresponding cells INBOUNDARY cut-faces:
   ! to be used for interpolation of H, etc.
   TESTVAR = IBM_CGSC
   CUT_CELL_LOOP2 : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH

      NCELL = MESHES(NM)%CUT_CELL(ICC)%NCELL
      IJK(IAXIS:KAXIS) = MESHES(NM)%CUT_CELL(ICC)%IJK(IAXIS:KAXIS)
      I = IJK(IAXIS); J = IJK(JAXIS); K = IJK(KAXIS)
      IF(SOLID(CELL_INDEX(I,J,K))) CYCLE
      MIN_DIST_VEL = DIST_THRES*MIN(DXCELL(I),DYCELL(J),DZCELL(K))

      ! First Cartesian centroid:
      XYZ(IAXIS:KAXIS) = (/ XCELL(I), YCELL(J), ZCELL(K) /)

      NPE_LIST_START = 0
      ALLOCATE(INT_NPE(LOW_IND:HIGH_IND,0:0,1:INT_N_EXT_PTS,0:CUT_CELL(ICC)%NCELL), &
               INT_IJK(IAXIS:KAXIS,(CUT_CELL(ICC)%NCELL+1)*DELTA_INT),                      &
               INT_COEF((CUT_CELL(ICC)%NCELL+1)*DELTA_INT),INT_NOUT(IAXIS:KAXIS,0:CUT_CELL(ICC)%NCELL))

      ! Now cut-cell volumes:
      ICELL_LOOP : DO ICELL=0,NCELL

         IF(ICELL > 0) XYZ(IAXIS:KAXIS)=MESHES(NM)%CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,ICELL)

         ! Initialize closest inboundary point data:
         DISTANCE            = 1._EB / GEOMEPS
         LASTDOTNVEC         =-1._EB / GEOMEPS
         FOUND_POINT         = .FALSE.
         XYZ_PP(IAXIS:KAXIS) = 0._EB
         FOUND_INBFC(1:3)    = 0

         JCC_LOOP : DO JCC=1,NCELL

            ! Find closest point and Inboundary cut-face:
            NFC_CC = MESHES(NM)%CUT_CELL(ICC)%CCELEM(1,JCC)
            DO CCFC=1,NFC_CC

               ICFC = MESHES(NM)%CUT_CELL(ICC)%CCELEM(CCFC+1,JCC)
               IF ( MESHES(NM)%CUT_CELL(ICC)%FACE_LIST(1,ICFC) /= IBM_FTYPE_CFINB) CYCLE

               ! Inboundary face number in CUT_FACE:
               INBFC     = MESHES(NM)%CUT_CELL(ICC)%FACE_LIST(4,ICFC)
               INBFC_LOC = MESHES(NM)%CUT_CELL(ICC)%FACE_LIST(5,ICFC)

               CALL GET_CLSPT_INBCF(NM,XYZ,INBFC,INBFC_LOC,XYZ_IP,DIST,FOUNDPT,INSEG)
               IF (FOUNDPT .AND. ((DIST-DISTANCE) < GEOMEPS)) THEN
                   IF (INSEG) THEN
                       BODTRI(1:2)  = CUT_FACE(INBFC)%BODTRI(1:2,INBFC_LOC)
                       ! normal vector to boundary surface triangle:
                       IBOD    = BODTRI(1)
                       IWSEL   = BODTRI(2)
                       NVEC(IAXIS:KAXIS) = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)
                       DV(IAXIS:KAXIS) = XYZ(IAXIS:KAXIS) - XYZ_IP(IAXIS:KAXIS)
                       NORM_DV = SQRT( DV(IAXIS)**2._EB + DV(JAXIS)**2._EB + DV(KAXIS)**2._EB )
                       IF(NORM_DV > GEOMEPS) THEN ! Point in segment not same as pt to interp to.
                          DV(IAXIS:KAXIS) = (1._EB / NORM_DV) * DV(IAXIS:KAXIS)
                          DOTNVEC = NVEC(IAXIS)*DV(IAXIS) + NVEC(JAXIS)*DV(JAXIS) + NVEC(KAXIS)*DV(KAXIS)
                          IF (DOTNVEC <= LASTDOTNVEC) CYCLE
                          LASTDOTNVEC = DOTNVEC
                       ENDIF
                   ENDIF
                   DISTANCE = DIST
                   XYZ_PP(IAXIS:KAXIS)   = XYZ_IP(IAXIS:KAXIS)
                   FOUND_INBFC(1:3) = (/ IBM_FTYPE_CFINB, INBFC, INBFC_LOC /) ! Inbound cut-face in CUT_FACE.
                   FOUND_POINT = .TRUE.
               ENDIF

            ENDDO

            ! If point not found, all cut-faces boundary of the icc, jcc volume
            ! are GASPHASE. There must be a SOLID point in the boundary of the
            ! underlying Cartesian cell. this is the closest point:
            IF (.NOT.FOUND_POINT) THEN
                ! Search for for CUT_CELL(icc) vertex points or other solid points:
                CALL GET_CLOSEPT_CCVT(NM,XYZ,ICC,XYZ_IP,DIST,FOUNDPT,IFCPT,IFCPT_LOC)
                IF (FOUNDPT .AND. ((DIST-DISTANCE) < GEOMEPS)) THEN
                   DISTANCE = DIST
                   XYZ_PP(IAXIS:KAXIS)   = XYZ_IP(IAXIS:KAXIS)
                   FOUND_INBFC(1:3) = (/ IBM_FTYPE_SVERT, IFCPT, IFCPT_LOC /) ! SOLID vertex in CUT_FACE.
                   FOUND_POINT = .TRUE.
                ENDIF
            ENDIF

         ENDDO JCC_LOOP

         IF (.NOT.FOUND_POINT .AND. GET_CUTCELLS_VERBOSE) THEN
            IF(ICELL==0) THEN
               WRITE(LU_ERR,*) 'CF: Havent found closest point CART CELL. ICC=',ICC
            ELSE
               WRITE(LU_ERR,*) 'CF: Havent found closest point CUT CELL. ICC,JCC=',ICC,JCC
            ENDIF
         ENDIF

         ! Here test if point in boundary and interpolation point coincide:
         IF (DISTANCE <= MIN_DIST_VEL) THEN

            INT_NOUT(IAXIS:KAXIS,ICELL) = 0._EB
            INT_XN(0:INT_N_EXT_PTS) = 0._EB
            INT_CN(0:INT_N_EXT_PTS) = 0._EB; INT_CN(0) = 1._EB ! Boundary point coefficient:
            VIND = 0
            DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
                NPE_LIST_COUNT = 0
                INT_NPE(LOW_IND,VIND,EP,ICELL)  = NPE_LIST_START
                INT_NPE(HIGH_IND,VIND,EP,ICELL) = NPE_LIST_COUNT
                NPE_LIST_START = NPE_LIST_START + NPE_LIST_COUNT
            ENDDO

         ELSE ! DISTANCE <= MIN_DIST_VEL

            ! After this loop we have the closest boundary point to xyz and the
            ! cut-face it belongs. We need to use the normal out of the face (or the
            ! vertex to xyz direction to find fluid points on the stencil:
            ! The fluid points are points that lay on the plane outside in the
            ! largest Cartesian component direction of the normal.
            DIR_FCT = 1._EB
            IF (FOUND_INBFC(1) == IBM_FTYPE_CFINB) THEN ! closest point in INBOUNDARY cut-face.
                BODTRI(1:2) = CUT_FACE(FOUND_INBFC(2))%BODTRI(1:2,FOUND_INBFC(3))
                ! normal vector to boundary surface triangle:
                IBOD    = BODTRI(1)
                IWSEL   = BODTRI(2)
                NVEC(IAXIS:KAXIS) = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)
                DV(IAXIS:KAXIS) = XYZ(IAXIS:KAXIS) - XYZ_PP(IAXIS:KAXIS)
                DOTNVEC = NVEC(IAXIS)*DV(IAXIS) + NVEC(JAXIS)*DV(JAXIS) + NVEC(KAXIS)*DV(KAXIS)

                IF (DOTNVEC < 0._EB) DIR_FCT = -1._EB ! if normal to triangle has opposite dir change
                                                      ! search direction.
            ENDIF

            ! Versor to GASPHASE:
            IF (DIR_FCT > 0._EB) THEN ! Versor from boundary point to centroid
                P0(IAXIS:KAXIS) = XYZ_PP(IAXIS:KAXIS)
                P1(IAXIS:KAXIS) = XYZ(IAXIS:KAXIS)
            ELSE ! Viceversa
                P0(IAXIS:KAXIS) = XYZ(IAXIS:KAXIS)
                P1(IAXIS:KAXIS) = XYZ_PP(IAXIS:KAXIS)
            ENDIF
            DV(IAXIS:KAXIS)   = DIR_FCT * ( XYZ(IAXIS:KAXIS) - XYZ_PP(IAXIS:KAXIS) )
            NORM_DV           = SQRT( DV(IAXIS)**2._EB + DV(JAXIS)**2._EB + DV(KAXIS)**2._EB )
            DV(IAXIS:KAXIS) = (1._EB / NORM_DV) * DV(IAXIS:KAXIS) ! NOUT

            CALL GET_DELN(1.001_EB,DELN,DXCELL(I),DYCELL(J),DZCELL(K),NVEC=DV,CLOSE_PT=.TRUE.)

            ! Location of interpolation point XYZ(IAXIS:KAXIS) along the DV direction, origin in
            ! boundary point XYZ_PP(IAXIS:KAXIS):
            INT_NOUT(IAXIS:KAXIS,ICELL) = DV(IAXIS:KAXIS)
            INT_XN(0)               = DIR_FCT * NORM_DV
            INT_XN(1:INT_N_EXT_PTS) = 0._EB
            ! Initialize interpolation coefficients along the normal probe direction DV
            INT_CN(0) = 0._EB; ! Boundary point interpolation coefficient
            INT_CN(1:INT_N_EXT_PTS) = 0._EB;
            VIND = 0
            DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
               INT_XN(EP) = REAL(EP,EB)*DELN
               CALL GET_INTSTENCILS_EP(.FALSE.,VIND,XYZ_PP,INT_XN(EP),DV, &
                                       NPE_LIST_START,NPE_LIST_COUNT,INT_IJK,INT_COEF)
               ! Start position for interpolation stencil related to VIND=0, of external
               ! point EP related to cut-cell ICELL:
               INT_NPE(LOW_IND,VIND,EP,ICELL)  = NPE_LIST_START
               ! Number of stencil points on stencil for said cc.
               INT_NPE(HIGH_IND,VIND,EP,ICELL) = NPE_LIST_COUNT
               NPE_LIST_START = NPE_LIST_START + NPE_LIST_COUNT
            ENDDO

         ENDIF ! DISTANCE <= MIN_DIST_VEL

         CUT_CELL(ICC)%INT_XYZBF(IAXIS:KAXIS,ICELL) = XYZ_PP(IAXIS:KAXIS) ! xyz of boundary pt.
         CUT_CELL(ICC)%INT_INBFC(1:3,ICELL)         = FOUND_INBFC(1:3)  ! which INB cut-face bndry pt belongs to.
         CUT_CELL(ICC)%INT_NOUT(IAXIS:KAXIS,ICELL)  = INT_NOUT(IAXIS:KAXIS,ICELL)
         CUT_CELL(ICC)%INT_XN(0:INT_N_EXT_PTS,ICELL)= INT_XN(0:INT_N_EXT_PTS)
         CUT_CELL(ICC)%INT_CN(0:INT_N_EXT_PTS,ICELL)= INT_CN(0:INT_N_EXT_PTS)
         ! If size of CUT_CELL(ICC)%INT_IJK,DIM=2 is less than the size of INT_IJK, reallocate:
         SZ_1 = SIZE(CUT_CELL(ICC)%INT_IJK,DIM=2)
         SZ_2 = SIZE(INT_IJK,DIM=2)
         IF(SZ_2 > SZ_1) THEN
            ALLOCATE(INT_IJK_AUX(IAXIS:KAXIS,SZ_1),INT_COEF_AUX(1:SZ_1))
            INT_IJK_AUX(IAXIS:KAXIS,1:SZ_1)  = CUT_CELL(ICC)%INT_IJK(IAXIS:KAXIS,1:SZ_1)
            INT_COEF_AUX(1:SZ_1)             = CUT_CELL(ICC)%INT_COEF(1:SZ_1)
            DEALLOCATE(CUT_CELL(ICC)%INT_IJK, CUT_CELL(ICC)%INT_COEF)
            ALLOCATE(CUT_CELL(ICC)%INT_IJK(IAXIS:KAXIS,SZ_2)); CUT_CELL(ICC)%INT_IJK = IBM_UNDEFINED
            ALLOCATE(CUT_CELL(ICC)%INT_COEF(1:SZ_2)); CUT_CELL(ICC)%INT_COEF = 0._EB
            CUT_CELL(ICC)%INT_IJK(IAXIS:KAXIS,1:SZ_1)  = INT_IJK_AUX(IAXIS:KAXIS,1:SZ_1)
            CUT_CELL(ICC)%INT_COEF(1:SZ_1)             = INT_COEF_AUX(1:SZ_1)
            DEALLOCATE(INT_IJK_AUX,INT_COEF_AUX)
            DEALLOCATE(CUT_CELL(ICC)%INT_CCVARS,CUT_CELL(ICC)%INT_NOMIND)
            ALLOCATE(CUT_CELL(ICC)%INT_CCVARS(1:N_INT_CCVARS,SZ_2)); CUT_CELL(ICC)%INT_CCVARS=0._EB
            ALLOCATE(CUT_CELL(ICC)%INT_NOMIND(LOW_IND:HIGH_IND,SZ_2)); CUT_CELL(ICC)%INT_NOMIND = IBM_UNDEFINED
         ENDIF
         VIND = 0
         DO EP=1,INT_N_EXT_PTS  ! External point for CELL ICELL
            INT_NPE_LO = INT_NPE(LOW_IND,VIND,EP,ICELL)
            INT_NPE_HI = INT_NPE(HIGH_IND,VIND,EP,ICELL)
            CUT_CELL(ICC)%INT_NPE(LOW_IND,VIND,EP,ICELL) = INT_NPE_LO
            CUT_CELL(ICC)%INT_NPE(HIGH_IND,VIND,EP,ICELL)= INT_NPE_HI
            DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
               CUT_CELL(ICC)%INT_IJK(IAXIS:KAXIS,INPE)  = INT_IJK(IAXIS:KAXIS,INPE)
               CUT_CELL(ICC)%INT_COEF(INPE)             = INT_COEF(INPE)
            ENDDO
         ENDDO

      ENDDO ICELL_LOOP
      DEALLOCATE(INT_NPE,INT_IJK,INT_COEF,INT_NOUT)

   ENDDO CUT_CELL_LOOP2

   ! Compute stencils for RCEDGES, regular edges connecting cut and regular faces, and IBEDGES, solid edges next to cut-faces:
   RCEDGE_LOOP_1 : DO IEDGE=1,MESHES(NM)%IBM_NRCEDGE
      ALLOCATE(IBM_RCEDGE(IEDGE)%XB_IB(-2:2),IBM_RCEDGE(IEDGE)%SURF_INDEX(-2:2),&
      IBM_RCEDGE(IEDGE)%DUIDXJ(-2:2),IBM_RCEDGE(IEDGE)%MU_DUIDXJ(-2:2))
      ALLOCATE(IBM_RCEDGE(IEDGE)%INT_NPE(LOW_IND:HIGH_IND,0:KAXIS,1:INT_N_EXT_PTS,-2:2))
      IBM_RCEDGE(IEDGE)%XB_IB(-2:2)      = 0._EB
      IBM_RCEDGE(IEDGE)%SURF_INDEX(-2:2) = -1
      ! IBM_RCEDGE(IEDGE)%PROCESS_EDGE_ORIENTATION(-2:2) = .FALSE. ! Process Orientation in double loop.
      ! IBM_RCEDGE(IEDGE)%EDGE_IN_MESH(-2:2)             = .TRUE.  ! Always true for RCEDGES, no need to mesh_cc_exchange variables.
      IBM_RCEDGE(IEDGE)%INT_NPE                          = 0       ! Required to avoid segfault in comm.

      IE = MESHES(NM)%IBM_RCEDGE(IEDGE)%IE
      II     = IJKE( 1,IE)
      JJ     = IJKE( 2,IE)
      KK     = IJKE( 3,IE)
      IEC    = IJKE( 4,IE) ! IEC is the edges X1AXIS

      ! First: Loop over all possible face orientations of edge to define XB_IB, SURF_INDEX, PROCESS_EDGE_ORIENTATION:
      ORIENTATION_LOOP_RC_1: DO IS=1,3
         IF (IS==IEC) CYCLE ORIENTATION_LOOP_RC_1
         SIGN_LOOP_RC_1: DO I_SGN=-1,1,2

            ! Determine Index_Coordinate_Direction
            ! IEC=1, ICD=1 refers to DWDY; ICD=2 refers to DVDZ
            ! IEC=2, ICD=1 refers to DUDZ; ICD=2 refers to DWDX
            ! IEC=3, ICD=1 refers to DVDX; ICD=2 refers to DUDY

            IF (IS>IEC) ICD = IS-IEC
            IF (IS<IEC) ICD = IS-IEC+3
            ICD_SGN = I_SGN * ICD

            ! With ICD_SGN check if face:
            ! IBEDGE IEC=IAXIS => ICD_SGN=-2 => FACE  low Z normal to JAXIS.
            !                     ICD_SGN=-1 => FACE  low Y normal to KAXIS.
            !                     ICD_SGN= 1 => FACE high Y normal to KAXIS.
            !                     ICD_SGN= 2 => FACE high Z normal to JAXIS.
            ! IBEDGE IEC=JAXIS => ICD_SGN=-2 => FACE  low X normal to KAXIS.
            !                     ICD_SGN=-1 => FACE  low Z normal to IAXIS.
            !                     ICD_SGN= 1 => FACE high Z normal to IAXIS.
            !                     ICD_SGN= 2 => FACE high X normal to KAXIS.
            ! IBEDGE IEC=KAXIS => ICD_SGN=-2 => FACE  low Y normal to IAXIS.
            !                     ICD_SGN=-1 => FACE  low X normal to JAXIS.
            !                     ICD_SGN= 1 => FACE high X normal to JAXIS.
            !                     ICD_SGN= 2 => FACE high Y normal to IAXIS.
            ! is GASPHASE cut-face.
            SELECT CASE(IEC)
               CASE(IAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE( 1); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=KAXIS
                     CASE( 2); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=JAXIS
                  END SELECT
                  ! Compute XB_IB: For XB_IB we use the sum of gas cut-faces in the face and compare it with the face AREA:
                  AREA_CF = 0._EB; ICF = FCVAR(IIF,JJF,KKF,IBM_IDCF,FAXIS)
                  IF(ICF>0) AREA_CF = SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))
                  DXX(1)  = DY(JJF); DXX(2)  = DZ(KKF); DEL_IBEDGE = DX(IIF)
                  IF (FAXIS==JAXIS) THEN
                     IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN) = DXX(2) ! Twice Distance to velocity collocation point.
                     IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)==IBM_CUTCFE) THEN
                        IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN)=(AREA_CF/DEL_IBEDGE)
                        ! SURF_INDEX:
                        IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                           ! Low side cut-cell: Load first cut-face SURF_INDEX:
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ELSEIF(CCVAR(IIF,JJF+1,KKF,IBM_IDCF)>0) THEN
                           ! High side cut-cell: Load first cut-face SURF_INDEX:
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF+1,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ENDIF
                     ENDIF
                  ELSE ! IF(FAXIS==KAXIS) THEN
                     IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN) = DXX(1) ! Twice Distance to velocity collocation point.
                     IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)==IBM_CUTCFE) THEN
                        IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN)=(AREA_CF/DEL_IBEDGE)
                        ! SURF_INDEX:
                        IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ELSEIF(CCVAR(IIF,JJF,KKF+1,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF+1,IBM_IDCF))%SURF_INDEX(1)
                        ENDIF
                     ENDIF
                  ENDIF

               CASE(JAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE( 1); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=IAXIS
                     CASE( 2); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                  END SELECT
                  ! Compute XB_IB: For XB_IB we use the sum of gas cut-faces in the face and compare it with the face AREA:
                  AREA_CF = 0._EB; ICF = FCVAR(IIF,JJF,KKF,IBM_IDCF,FAXIS)
                  IF(ICF>0) AREA_CF = SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))
                  DXX(1)  = DZ(KKF); DXX(2)  = DX(IIF); DEL_IBEDGE = DY(JJF)
                  IF (FAXIS==KAXIS) THEN
                     IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN) = DXX(2) ! Twice Distance to velocity collocation point.
                     IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)==IBM_CUTCFE) THEN
                        IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN)=(AREA_CF/DEL_IBEDGE)
                        ! SURF_INDEX:
                        IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ELSEIF(CCVAR(IIF,JJF,KKF+1,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF+1,IBM_IDCF))%SURF_INDEX(1)
                        ENDIF
                     ENDIF
                  ELSE ! IF(FAXIS==IAXIS) THEN
                     IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN) = DXX(1) ! Twice Distance to velocity collocation point.
                     IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)==IBM_CUTCFE) THEN
                        IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN)=(AREA_CF/DEL_IBEDGE)
                        ! SURF_INDEX:
                        IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ELSEIF(CCVAR(IIF+1,JJF,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF+1,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ENDIF
                     ENDIF
                  ENDIF

               CASE(KAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 1); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 2); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=IAXIS
                  END SELECT
                  ! Compute XB_IB: For XB_IB we use the sum of gas cut-faces in the face and compare it with the face AREA:
                  AREA_CF = 0._EB; ICF = FCVAR(IIF,JJF,KKF,IBM_IDCF,FAXIS)
                  IF(ICF>0) AREA_CF = SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))
                  DXX(1)  = DX(IIF); DXX(2)  = DY(JJF); DEL_IBEDGE = DZ(KKF)
                  IF (FAXIS==IAXIS) THEN
                     IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN) = DXX(2) ! Twice Distance to velocity collocation point.
                     IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)==IBM_CUTCFE) THEN
                        IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN)=(AREA_CF/DEL_IBEDGE)
                        ! SURF_INDEX:
                        IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ELSEIF(CCVAR(IIF+1,JJF,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF+1,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ENDIF
                     ENDIF
                  ELSE ! IF(FAXIS==JAXIS) THEN
                     IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN) = DXX(1) ! Twice Distance to velocity collocation point.
                     IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)==IBM_CUTCFE) THEN
                        IBM_RCEDGE(IEDGE)%XB_IB(ICD_SGN)=(AREA_CF/DEL_IBEDGE)
                        ! SURF_INDEX:
                        IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ELSEIF(CCVAR(IIF,JJF+1,KKF,IBM_IDCF)>0) THEN
                           IBM_RCEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF+1,KKF,IBM_IDCF))%SURF_INDEX(1)
                        ENDIF
                     ENDIF
                  ENDIF

             END SELECT

          ENDDO SIGN_LOOP_RC_1
       ENDDO ORIENTATION_LOOP_RC_1

   ENDDO RCEDGE_LOOP_1

   ! Dummy allocation for now:
   IBEDGE_LOOP1 : DO IEDGE=1,MESHES(NM)%IBM_NIBEDGE

      ALLOCATE(IBM_IBEDGE(IEDGE)%XB_IB(-2:2),IBM_IBEDGE(IEDGE)%SURF_INDEX(-2:2),&
               IBM_IBEDGE(IEDGE)%PROCESS_EDGE_ORIENTATION(-2:2),IBM_IBEDGE(IEDGE)%EDGE_IN_MESH(-2:2))
      ALLOCATE(IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND:HIGH_IND,0:KAXIS,1:INT_N_EXT_PTS,-2:2))
      IBM_IBEDGE(IEDGE)%XB_IB(-2:2)      = 0._EB
      IBM_IBEDGE(IEDGE)%SURF_INDEX(-2:2) = 0
      IBM_IBEDGE(IEDGE)%PROCESS_EDGE_ORIENTATION(-2:2) = .FALSE. ! Process Orientation in double loop.
      IBM_IBEDGE(IEDGE)%EDGE_IN_MESH(-2:2)             = .FALSE. ! If true, no need to mesh_cc_exchange variables.
      IBM_IBEDGE(IEDGE)%INT_NPE                        = 0 ! Required to avoid segfault in comm.

      IE = MESHES(NM)%IBM_IBEDGE(IEDGE)%IE
      II     = IJKE( 1,IE)
      JJ     = IJKE( 2,IE)
      KK     = IJKE( 3,IE)
      IEC    = IJKE( 4,IE) ! IEC is the edges X1AXIS

      ! First: Loop over all possible face orientations of edge to define XB_IB, SURF_INDEX, PROCESS_EDGE_ORIENTATION:
      ORIENTATION_LOOP_1: DO IS=1,3
         IF (IS==IEC) CYCLE ORIENTATION_LOOP_1
         SIGN_LOOP_1: DO I_SGN=-1,1,2

            ! Determine Index_Coordinate_Direction
            ! IEC=1, ICD=1 refers to DWDY; ICD=2 refers to DVDZ
            ! IEC=2, ICD=1 refers to DUDZ; ICD=2 refers to DWDX
            ! IEC=3, ICD=1 refers to DVDX; ICD=2 refers to DUDY

            IF (IS>IEC) ICD = IS-IEC
            IF (IS<IEC) ICD = IS-IEC+3
            ICD_SGN = I_SGN * ICD

            ! With ICD_SGN check if face:
            ! IBEDGE IEC=IAXIS => ICD_SGN=-2 => FACE  low Z normal to JAXIS.
            !                     ICD_SGN=-1 => FACE  low Y normal to KAXIS.
            !                     ICD_SGN= 1 => FACE high Y normal to KAXIS.
            !                     ICD_SGN= 2 => FACE high Z normal to JAXIS.
            ! IBEDGE IEC=JAXIS => ICD_SGN=-2 => FACE  low X normal to KAXIS.
            !                     ICD_SGN=-1 => FACE  low Z normal to IAXIS.
            !                     ICD_SGN= 1 => FACE high Z normal to IAXIS.
            !                     ICD_SGN= 2 => FACE high X normal to KAXIS.
            ! IBEDGE IEC=KAXIS => ICD_SGN=-2 => FACE  low Y normal to IAXIS.
            !                     ICD_SGN=-1 => FACE  low X normal to JAXIS.
            !                     ICD_SGN= 1 => FACE high X normal to JAXIS.
            !                     ICD_SGN= 2 => FACE high Y normal to IAXIS.
            ! is GASPHASE cut-face.
            SELECT CASE(IEC)
               CASE(IAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE( 1); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=KAXIS
                     CASE( 2); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=JAXIS
                  END SELECT
                  ! Drop if face is not type CUTCFE:
                  IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP_1
                  ! Compute XB_IB, SURF_INDEX:
                  ! For XB_IB we use the sum of gas cut-faces in the face and compare it with the face AREA:
                  AREA_CF = 0._EB; ICF = FCVAR(IIF,JJF,KKF,IBM_IDCF,FAXIS)
                  IF(ICF>0) AREA_CF = SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))
                  DXX(1)  = DY(JJF); DXX(2)  = DZ(KKF); DEL_IBEDGE = DX(IIF)
                  IF (FAXIS==JAXIS) THEN
                     ! XB_IB:
                     IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN) = -(DXX(2)-AREA_CF/DEL_IBEDGE) !-ve dist Bound to IBEDGE opposed to normal.
                     ! SURF_INDEX:
                     IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                        ! Low side cut-cell: Load first cut-face SURF_INDEX:
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ELSEIF(CCVAR(IIF,JJF+1,KKF,IBM_IDCF)>0) THEN
                        ! High side cut-cell: Load first cut-face SURF_INDEX:
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF+1,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ENDIF
                  ELSE ! IF(FAXIS==KAXIS) THEN
                     ! XB_IB:
                     IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN) = -(DXX(1)-AREA_CF/DEL_IBEDGE) !-ve dist Bound to IBEDGE opposed to normal.
                     ! SURF_INDEX:
                     IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ELSEIF(CCVAR(IIF,JJF,KKF+1,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF+1,IBM_IDCF))%SURF_INDEX(1)
                     ENDIF
                  ENDIF

                  ! Now search where the EP external stress edge will be defined:
                  XB_IB = IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN)
                  SKIP_FCT = 1
                  IF (FAXIS==JAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     JEP=JJ; KEP=KK+SKIP_FCT*I_SGN
                  ELSE ! IF(FAXIS==KAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     JEP=JJ+SKIP_FCT*I_SGN; KEP=KK
                  ENDIF
                  IF( JEP<=JBAR .AND. JEP>=0 .AND. KEP<=KBAR .AND. KEP>=0 ) IBM_IBEDGE(IEDGE)%EDGE_IN_MESH(ICD_SGN) = .TRUE.

               CASE(JAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE( 1); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=IAXIS
                     CASE( 2); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                  END SELECT
                  IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP_1
                  ! Compute XB_IB, SURF_INDEX:
                  ! For XB_IB we use the sum of gas cut-faces in the face and compare it with the face AREA:
                  AREA_CF = 0._EB; ICF = FCVAR(IIF,JJF,KKF,IBM_IDCF,FAXIS)
                  IF(ICF>0) AREA_CF = SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))
                  DXX(1)  = DZ(KKF); DXX(2)  = DX(IIF); DEL_IBEDGE = DY(JJF)
                  IF (FAXIS==KAXIS) THEN
                     ! XB_IB:
                     IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN) = -(DXX(2)-AREA_CF/DEL_IBEDGE) !-ve dist Bound to IBEDGE opposed to normal.
                     ! SURF_INDEX:
                     IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ELSEIF(CCVAR(IIF,JJF,KKF+1,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF+1,IBM_IDCF))%SURF_INDEX(1)
                     ENDIF
                  ELSE ! IF(FAXIS==IAXIS) THEN
                     ! XB_IB:
                     IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN) = -(DXX(1)-AREA_CF/DEL_IBEDGE) !-ve dist Bound to IBEDGE opposed to normal.
                     ! SURF_INDEX:
                     IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ELSEIF(CCVAR(IIF+1,JJF,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF+1,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ENDIF
                  ENDIF

                  ! Now search where the EP external stress edge will be defined:
                  XB_IB = IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN)
                  SKIP_FCT = 1
                  IF (FAXIS==KAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II+SKIP_FCT*I_SGN; KEP=KK
                  ELSE ! IF(FAXIS==IAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; KEP=KK+SKIP_FCT*I_SGN
                  ENDIF
                  IF( IEP<=IBAR .AND. IEP>=0 .AND. KEP<=KBAR .AND. KEP>=0 ) IBM_IBEDGE(IEDGE)%EDGE_IN_MESH(ICD_SGN) = .TRUE.

               CASE(KAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 1); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 2); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=IAXIS
                  END SELECT
                  IF(FCVAR(IIF,JJF,KKF,IBM_FGSC,FAXIS)/=IBM_CUTCFE) CYCLE SIGN_LOOP_1
                  ! Compute XB_IB, SURF_INDEX:
                  ! For XB_IB we use the sum of gas cut-faces in the face and compare it with the face AREA:
                  AREA_CF = 0._EB; ICF = FCVAR(IIF,JJF,KKF,IBM_IDCF,FAXIS)
                  IF(ICF>0) AREA_CF = SUM(CUT_FACE(ICF)%AREA(1:CUT_FACE(ICF)%NFACE))
                  DXX(1)  = DX(IIF); DXX(2)  = DY(JJF); DEL_IBEDGE = DZ(KKF)
                  IF (FAXIS==IAXIS) THEN
                     ! XB_IB:
                     IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN) = -(DXX(2)-AREA_CF/DEL_IBEDGE) !-ve dist Bound to IBEDGE opposed to normal.
                     ! SURF_INDEX:
                     IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ELSEIF(CCVAR(IIF+1,JJF,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF+1,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ENDIF
                  ELSE ! IF(FAXIS==JAXIS) THEN
                     ! XB_IB:
                     IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN) = -(DXX(1)-AREA_CF/DEL_IBEDGE) !-ve dist Bound to IBEDGE opposed to normal.
                     ! SURF_INDEX:
                     IF (CCVAR(IIF,JJF,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ELSEIF(CCVAR(IIF,JJF+1,KKF,IBM_IDCF)>0) THEN
                        IBM_IBEDGE(IEDGE)%SURF_INDEX(ICD_SGN) = CUT_FACE(CCVAR(IIF,JJF+1,KKF,IBM_IDCF))%SURF_INDEX(1)
                     ENDIF
                  ENDIF

                  ! Now search where the EP external stress edge will be defined:
                  XB_IB = IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN)
                  SKIP_FCT = 1
                  IF (FAXIS==IAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ+SKIP_FCT*I_SGN
                  ELSE ! IF(FAXIS==JAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II+SKIP_FCT*I_SGN; JEP=JJ
                  ENDIF
                  IF( IEP<=IBAR .AND. IEP>=0 .AND. JEP<=JBAR .AND. JEP>=0 ) IBM_IBEDGE(IEDGE)%EDGE_IN_MESH(ICD_SGN) = .TRUE.

            END SELECT

            IBM_IBEDGE(IEDGE)%PROCESS_EDGE_ORIENTATION(ICD_SGN) = .TRUE.

         ENDDO SIGN_LOOP_1
      ENDDO ORIENTATION_LOOP_1

      ! If the edge orientation is not EDGE_IN_MESH, velocity, MU data for EP is communicated:
      NPE_LIST_START = 0
      ALLOCATE(INT_NPE(LOW_IND:HIGH_IND,0:KAXIS,1:INT_N_EXT_PTS,-2:2),INT_IJK(IAXIS:KAXIS,32)); INT_NPE = 0; INT_IJK = 0;
      ALLOCATE(INT_DCOEF(32,1)); INT_DCOEF = 0._EB
      ! First cell centered Variable MU:
      EP   = 1; N_CVAR_START = NPE_LIST_START
      ORIENTATION_LOOP_2: DO IS=1,3
         IF (IS==IEC) CYCLE ORIENTATION_LOOP_2
         SIGN_LOOP_2: DO I_SGN=-1,1,2
            IF (IS>IEC) ICD = IS-IEC
            IF (IS<IEC) ICD = IS-IEC+3
            ICD_SGN = I_SGN * ICD

            IF(.NOT.IBM_IBEDGE(IEDGE)%PROCESS_EDGE_ORIENTATION(ICD_SGN)) CYCLE SIGN_LOOP_2
            IF(IBM_IBEDGE(IEDGE)%EDGE_IN_MESH(ICD_SGN)) CYCLE SIGN_LOOP_2

            XB_IB = IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN)

            SELECT CASE(IEC)
               CASE(IAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE( 1); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=KAXIS
                     CASE( 2); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=JAXIS
                  END SELECT
                  DXX(1)  = DY(JJF); DXX(2)  = DZ(KKF)
                  SKIP_FCT = 1
                  IF (FAXIS==JAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ; KEP=KK+SKIP_FCT*I_SGN
                  ELSE ! IF(FAXIS==KAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ+SKIP_FCT*I_SGN; KEP=KK
                  ENDIF
                  ! Add I,J,K locations of cells:
                  INDS(1:2,IAXIS) = (/0, 0/)
                  INDS(1:2,JAXIS) = (/0, 1/)
                  INDS(1:2,KAXIS) = (/0, 1/)

               CASE(JAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE( 1); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=IAXIS
                     CASE( 2); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                  END SELECT
                  DXX(1)  = DZ(KKF); DXX(2)  = DX(IIF)
                  SKIP_FCT = 1
                  IF (FAXIS==KAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II+SKIP_FCT*I_SGN; JEP=JJ; KEP=KK
                  ELSE ! IF(FAXIS==IAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ; KEP=KK+SKIP_FCT*I_SGN
                  ENDIF
                  ! Add I,J,K locations of cells:
                  INDS(1:2,IAXIS) = (/0, 1/)
                  INDS(1:2,JAXIS) = (/0, 0/)
                  INDS(1:2,KAXIS) = (/0, 1/)

               CASE(KAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 1); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 2); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=IAXIS
                  END SELECT
                  DXX(1)  = DX(IIF); DXX(2)  = DY(JJF)
                  SKIP_FCT = 1
                  IF (FAXIS==IAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ+SKIP_FCT*I_SGN; KEP=KK
                  ELSE ! IF(FAXIS==JAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II+SKIP_FCT*I_SGN; JEP=JJ; KEP=KK
                  ENDIF
                  ! Add I,J,K locations of cells:
                  INDS(1:2,IAXIS) = (/0, 1/)
                  INDS(1:2,JAXIS) = (/0, 1/)
                  INDS(1:2,KAXIS) = (/0, 0/)

            END SELECT

            ! ADD all
            VIND = 0; NPE_LIST_COUNT  = 0
            DO K=INDS(1,KAXIS),INDS(2,KAXIS)
               DO J=INDS(1,JAXIS),INDS(2,JAXIS)
                  DO I=INDS(1,IAXIS),INDS(2,IAXIS)
                     ! IF(SOLID(CELL_INDEX(IEP+I,JEP+J,KEP+K))) CYCLE ! Cycle solid cells. Can't use it here as is (overrun).
                     IF(CCVAR(IEP+I,JEP+J,KEP+K,IBM_CGSC)==IBM_SOLID) CYCLE
                     NPE_LIST_COUNT = NPE_LIST_COUNT + 1
                     INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/IEP+I,JEP+J,KEP+K/)
                  ENDDO
               ENDDO
            ENDDO
            ! Start position and number of points for cell centered vars related to EP edge of ICD_SGN orientation:
            INT_NPE(LOW_IND,VIND,EP,ICD_SGN)  = NPE_LIST_START
            INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_LIST_COUNT
            NPE_LIST_START = NPE_LIST_START + NPE_LIST_COUNT

         ENDDO SIGN_LOOP_2
      ENDDO ORIENTATION_LOOP_2
      ! Number of cell centered stencil points:
      N_CVAR_COUNT = NPE_LIST_START

      ! Now add Face Variables for the two directions normal to IEC:
      N_FVAR_START = N_CVAR_START + N_CVAR_COUNT
      ORIENTATION_LOOP_3: DO IS=1,3
         IF (IS==IEC) CYCLE ORIENTATION_LOOP_3
         SIGN_LOOP_3: DO I_SGN=-1,1,2
            IF (IS>IEC) ICD = IS-IEC
            IF (IS<IEC) ICD = IS-IEC+3
            ICD_SGN = I_SGN * ICD

            IF(.NOT.IBM_IBEDGE(IEDGE)%PROCESS_EDGE_ORIENTATION(ICD_SGN)) CYCLE SIGN_LOOP_3
            IF(IBM_IBEDGE(IEDGE)%EDGE_IN_MESH(ICD_SGN)) CYCLE SIGN_LOOP_3

            XB_IB = IBM_IBEDGE(IEDGE)%XB_IB(ICD_SGN)

            SELECT CASE(IEC)
               CASE(IAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE( 1); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=KAXIS
                     CASE( 2); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=JAXIS
                  END SELECT
                  DXX(1)  = DY(JJF); DXX(2)  = DZ(KKF)
                  SKIP_FCT = 1
                  IF (FAXIS==JAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ; KEP=KK+SKIP_FCT*I_SGN
                  ELSE ! IF(FAXIS==KAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ+SKIP_FCT*I_SGN; KEP=KK
                  ENDIF

                  ! V velocities in EP for KEP,KEP+1:
                  VIND = JAXIS; NPE_LIST_COUNT = 0
                  DO K=0,1
                    NPE_LIST_COUNT = NPE_LIST_COUNT + 1
                    INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/IEP  ,JEP  ,KEP+K/)
                    INT_DCOEF(NPE_LIST_START+NPE_LIST_COUNT,1) = REAL(2*K-1,EB)/DXX(2)
                  ENDDO
                  INT_NPE(LOW_IND,VIND,EP,ICD_SGN)  = NPE_LIST_START
                  INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_LIST_COUNT
                  NPE_LIST_START                    = NPE_LIST_START + NPE_LIST_COUNT

                  ! W Velocities in EP for JEP,JEP+1:
                  VIND = KAXIS; NPE_LIST_COUNT = 0
                  DO J=0,1
                     NPE_LIST_COUNT = NPE_LIST_COUNT + 1
                     INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/IEP  ,JEP+J,KEP  /)
                     INT_DCOEF(NPE_LIST_START+NPE_LIST_COUNT,1) = REAL(2*J-1,EB)/DXX(1)
                  ENDDO
                  INT_NPE(LOW_IND,VIND,EP,ICD_SGN)  = NPE_LIST_START
                  INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_LIST_COUNT
                  NPE_LIST_START                    = NPE_LIST_START + NPE_LIST_COUNT

               CASE(JAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE( 1); IIF=II  ; JJF=JJ  ; KKF=KK+1; FAXIS=IAXIS
                     CASE( 2); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=KAXIS
                  END SELECT
                  DXX(1)  = DZ(KKF); DXX(2)  = DX(IIF)
                  SKIP_FCT = 1
                  IF (FAXIS==KAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II+SKIP_FCT*I_SGN; JEP=JJ; KEP=KK
                  ELSE ! IF(FAXIS==IAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ; KEP=KK+SKIP_FCT*I_SGN
                  ENDIF

                  ! W Velocities in EP for IEP,IEP+1:
                  VIND = KAXIS; NPE_LIST_COUNT = 0
                  DO I=0,1
                     NPE_LIST_COUNT = NPE_LIST_COUNT + 1
                     INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/IEP+I,JEP  ,KEP  /)
                     INT_DCOEF(NPE_LIST_START+NPE_LIST_COUNT,1) = REAL(2*I-1,EB)/DXX(2)
                  ENDDO
                  INT_NPE(LOW_IND,VIND,EP,ICD_SGN)  = NPE_LIST_START
                  INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_LIST_COUNT
                  NPE_LIST_START                    = NPE_LIST_START + NPE_LIST_COUNT

                  ! U Velocities in EP for KEP,KEP+1:
                  VIND = IAXIS; NPE_LIST_COUNT = 0
                  DO K=0,1
                     NPE_LIST_COUNT = NPE_LIST_COUNT + 1
                     INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/IEP  ,JEP  ,KEP+K/)
                     INT_DCOEF(NPE_LIST_START+NPE_LIST_COUNT,1) = REAL(2*K-1,EB)/DXX(1)
                  ENDDO
                  INT_NPE(LOW_IND,VIND,EP,ICD_SGN)  = NPE_LIST_START
                  INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_LIST_COUNT
                  NPE_LIST_START                    = NPE_LIST_START + NPE_LIST_COUNT

               CASE(KAXIS)
                  ! Define Face indexes and normal axis FAXIS.
                  SELECT CASE(ICD_SGN)
                     CASE(-2); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=IAXIS
                     CASE(-1); IIF=II  ; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 1); IIF=II+1; JJF=JJ  ; KKF=KK  ; FAXIS=JAXIS
                     CASE( 2); IIF=II  ; JJF=JJ+1; KKF=KK  ; FAXIS=IAXIS
                  END SELECT
                  DXX(1)  = DX(IIF); DXX(2)  = DY(JJF)
                  SKIP_FCT = 1
                  IF (FAXIS==IAXIS) THEN
                     DEL_EP = DXX(2) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(2) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II; JEP=JJ+SKIP_FCT*I_SGN; KEP=KK
                  ELSE ! IF(FAXIS==JAXIS) THEN
                     DEL_EP = DXX(1) - ABS(XB_IB)
                     IF( DEL_EP < THRES_FCT_EP*DXX(1) ) SKIP_FCT = 2 ! Pick next EP point +2*I_SGN
                     IEP=II+SKIP_FCT*I_SGN; JEP=JJ; KEP=KK
                  ENDIF

                  ! U Velocities in EP for JEP,JEP+1:
                  VIND = IAXIS; NPE_LIST_COUNT = 0
                  DO J=0,1
                     NPE_LIST_COUNT = NPE_LIST_COUNT + 1
                     INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/IEP  ,JEP+J,KEP  /)
                     INT_DCOEF(NPE_LIST_START+NPE_LIST_COUNT,1) = REAL(2*J-1,EB)/DXX(2)
                  ENDDO
                  INT_NPE(LOW_IND,VIND,EP,ICD_SGN)  = NPE_LIST_START
                  INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_LIST_COUNT
                  NPE_LIST_START                    = NPE_LIST_START + NPE_LIST_COUNT

                  ! V velocities in EP for IEP,IEP+1:
                  VIND = JAXIS; NPE_LIST_COUNT = 0
                  DO I=0,1
                    NPE_LIST_COUNT = NPE_LIST_COUNT + 1
                    INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/IEP+I,JEP  ,KEP  /)
                    INT_DCOEF(NPE_LIST_START+NPE_LIST_COUNT,1) = REAL(2*I-1,EB)/DXX(1)
                  ENDDO
                  INT_NPE(LOW_IND,VIND,EP,ICD_SGN)  = NPE_LIST_START
                  INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_LIST_COUNT
                  NPE_LIST_START                    = NPE_LIST_START + NPE_LIST_COUNT

            END SELECT

         ENDDO SIGN_LOOP_3
      ENDDO ORIENTATION_LOOP_3
      N_FVAR_COUNT = NPE_LIST_START - N_FVAR_START

      IF (NPE_LIST_START > 0) THEN
         ! Allocate INT_IJK, INT_CVARS, INT_FVARS:
         ALLOCATE(IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,NPE_LIST_START))
         ALLOCATE(IBM_IBEDGE(IEDGE)%INT_CVARS(1:N_INT_EP_CVARS,N_CVAR_START+1:N_CVAR_START+N_CVAR_COUNT))
         ALLOCATE(IBM_IBEDGE(IEDGE)%INT_FVARS(1:N_INT_EP_FVARS,N_FVAR_START+1:N_FVAR_START+N_FVAR_COUNT))
         IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND:HIGH_IND,0:KAXIS,1:INT_N_EXT_PTS,-2:2) = &
                           INT_NPE(LOW_IND:HIGH_IND,0:KAXIS,1:INT_N_EXT_PTS,-2:2)
         IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,1:NPE_LIST_START) = INT_IJK(IAXIS:KAXIS,1:NPE_LIST_START)
         IBM_IBEDGE(IEDGE)%INT_CVARS = 0._EB; IBM_IBEDGE(IEDGE)%INT_FVARS = 0._EB
         ALLOCATE(IBM_IBEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,NPE_LIST_START)); IBM_IBEDGE(IEDGE)%INT_NOMIND = IBM_UNDEFINED
         ALLOCATE(IBM_IBEDGE(IEDGE)%INT_DCOEF(NPE_LIST_START,1));
         IBM_IBEDGE(IEDGE)%INT_DCOEF(1:NPE_LIST_START,1) = INT_DCOEF(1:NPE_LIST_START,1)
      ENDIF

      DEALLOCATE(INT_NPE,INT_IJK,INT_DCOEF)

   ENDDO IBEDGE_LOOP1

   ! Up to this point we have the cut-faces (both GASPHASE and INBOUNDARY), cut-cell (both underlaying Cartesian and unstructured),
   ! regular forced edges.
   ! 1. CUT_FACE
   ! 2. CUT_CELL
   ! 3. IBM_RCEDGE
   ! 4. IBM_IBEDGE

   DO NOM=1,NMESHES
      ! Also considers the case NOM==NM as a regular case.
      ! Face Variables:
      ALLOCATE(MESHES(NM)%OMESH(NOM)%IIO_FC_R(DELTA_FC))
      ALLOCATE(MESHES(NM)%OMESH(NOM)%JJO_FC_R(DELTA_FC))
      ALLOCATE(MESHES(NM)%OMESH(NOM)%KKO_FC_R(DELTA_FC))
      ALLOCATE(MESHES(NM)%OMESH(NOM)%AXS_FC_R(DELTA_FC))
      ! Cell Variables:
      ALLOCATE(MESHES(NM)%OMESH(NOM)%IIO_CC_R(DELTA_FC))
      ALLOCATE(MESHES(NM)%OMESH(NOM)%JJO_CC_R(DELTA_FC))
      ALLOCATE(MESHES(NM)%OMESH(NOM)%KKO_CC_R(DELTA_FC))
   ENDDO

   ! Figure out which Regular face locations for this mesh are required for interpolation:
   ALLOCATE(IJKFACE2(LOW_IND:HIGH_IND,ISTR:IEND,JSTR:JEND,KSTR:KEND,IAXIS:KAXIS)); IJKFACE2 = IBM_UNDEFINED

   ! Figure out which other meshes this mesh will receive face centered variables from:
   ! Cut-faces stencils:
   DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      IF (CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE
      ! Underlying Cartesian and cut-faces:
      DO IFACE=0,CUT_FACE(ICF)%NFACE
         DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
            DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
               INT_NPE_LO = CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
               INT_NPE_HI = CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
               X1AXIS = VIND
               ALLOCATE(EP_TAG(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)); EP_TAG(:)=.FALSE.
               DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                  I = CUT_FACE(ICF)%INT_IJK(IAXIS,INPE)
                  J = CUT_FACE(ICF)%INT_IJK(JAXIS,INPE)
                  K = CUT_FACE(ICF)%INT_IJK(KAXIS,INPE)
                  SELECT CASE(X1AXIS)
                  CASE(IAXIS)
                     IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                        FLGX = (I >= ILO_FACE) .AND. (I <= IHI_FACE)
                        FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                        FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                        INNM = FLGX .AND. FLGY .AND. FLGZ
                        IF (INNM) THEN
                           NOM=NM; IIO=I; JJO=J; KKO=K
                        ELSE
                           CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XFACE(I),YCELL(J),ZCELL(K),NOM,IIO,JJO,KKO)
                        ENDIF
                        IF(NOM==0) EP_TAG(INPE) = .TRUE.
                        CALL ASSIGN_TO_FC_R
                     ENDIF
                  CASE(JAXIS)
                     IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                        FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                        FLGY = (J >= JLO_FACE) .AND. (J <= JHI_FACE)
                        FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                        INNM = FLGX .AND. FLGY .AND. FLGZ
                        IF (INNM) THEN
                           NOM=NM; IIO=I; JJO=J; KKO=K
                        ELSE
                           CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YFACE(J),ZCELL(K),NOM,IIO,JJO,KKO)
                        ENDIF
                        IF(NOM==0) EP_TAG(INPE) = .TRUE.
                        CALL ASSIGN_TO_FC_R
                     ENDIF
                  CASE(KAXIS)
                     IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                        FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                        FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                        FLGZ = (K >= KLO_FACE) .AND. (K <= KHI_FACE)
                        INNM = FLGX .AND. FLGY .AND. FLGZ
                        IF (INNM) THEN
                           NOM=NM; IIO=I; JJO=J; KKO=K
                        ELSE
                           CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YCELL(J),ZFACE(K),NOM,IIO,JJO,KKO)
                        ENDIF
                        IF(NOM==0) EP_TAG(INPE) = .TRUE.
                        CALL ASSIGN_TO_FC_R
                     ENDIF
                  END SELECT
                  CUT_FACE(ICF)%INT_NOMIND(LOW_IND:HIGH_IND,INPE) = IJKFACE2(LOW_IND:HIGH_IND,I,J,K,X1AXIS)
               ENDDO
               ! Now restrict count on cut-face :
               IF(ANY(EP_TAG .EQV. .TRUE.)) CALL RESTRICT_EP(IBM_FTYPE_CFGAS)
               DEALLOCATE(EP_TAG)
               ! Compute derivative coefficients.
               CALL COMPUTE_DCOEF(IBM_FTYPE_CFGAS)
            ENDDO
         ENDDO
      ENDDO
   ENDDO

   ! INBOUNDARY cut-faces:
   DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      IF (CUT_FACE(ICF)%STATUS /= IBM_INBOUNDARY) CYCLE
      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      ! Don't count cut-cells inside an OBST:
      IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
      DO IFACE=1,CUT_FACE(ICF)%NFACE
         DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
            DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
               INT_NPE_LO = CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
               INT_NPE_HI = CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
               X1AXIS = VIND
               ALLOCATE(EP_TAG(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)); EP_TAG(:)=.FALSE.
               DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                  I = CUT_FACE(ICF)%INT_IJK(IAXIS,INPE)
                  J = CUT_FACE(ICF)%INT_IJK(JAXIS,INPE)
                  K = CUT_FACE(ICF)%INT_IJK(KAXIS,INPE)
                  SELECT CASE(X1AXIS)
                  CASE(IAXIS)
                     IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                        FLGX = (I >= ILO_FACE) .AND. (I <= IHI_FACE)
                        FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                        FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                        INNM = FLGX .AND. FLGY .AND. FLGZ
                        IF (INNM) THEN
                           NOM=NM; IIO=I; JJO=J; KKO=K
                        ELSE
                           CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XFACE(I),YCELL(J),ZCELL(K),NOM,IIO,JJO,KKO)
                        ENDIF
                        IF(NOM==0) EP_TAG(INPE) = .TRUE.
                        CALL ASSIGN_TO_FC_R
                     ENDIF
                  CASE(JAXIS)
                     IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                        FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                        FLGY = (J >= JLO_FACE) .AND. (J <= JHI_FACE)
                        FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                        INNM = FLGX .AND. FLGY .AND. FLGZ
                        IF (INNM) THEN
                           NOM=NM; IIO=I; JJO=J; KKO=K
                        ELSE
                           CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YFACE(J),ZCELL(K),NOM,IIO,JJO,KKO)
                        ENDIF
                        IF(NOM==0) EP_TAG(INPE) = .TRUE.
                        CALL ASSIGN_TO_FC_R
                     ENDIF
                  CASE(KAXIS)
                     IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                        FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                        FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                        FLGZ = (K >= KLO_FACE) .AND. (K <= KHI_FACE)
                        INNM = FLGX .AND. FLGY .AND. FLGZ
                        IF (INNM) THEN
                           NOM=NM; IIO=I; JJO=J; KKO=K
                        ELSE
                           CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YCELL(J),ZFACE(K),NOM,IIO,JJO,KKO)
                        ENDIF
                        IF(NOM==0) EP_TAG(INPE) = .TRUE.
                        CALL ASSIGN_TO_FC_R
                     ENDIF
                  END SELECT
                  CUT_FACE(ICF)%INT_NOMIND(LOW_IND:HIGH_IND,INPE) = IJKFACE2(LOW_IND:HIGH_IND,I,J,K,X1AXIS)
               ENDDO
               ! Now restrict count on cut-face :
               IF(ANY(EP_TAG .EQV. .TRUE.)) CALL RESTRICT_EP(IBM_FTYPE_CFINB)
               DEALLOCATE(EP_TAG)
            ENDDO
         ENDDO
      ENDDO
   ENDDO

   ! Finally 1. RCEDGES:
   DO IEDGE=1,MESHES(NM)%IBM_NRCEDGE
      DO EP=1,INT_N_EXT_PTS  ! External point for IEDGE
         DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
            INT_NPE_LO = IBM_RCEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,0)
            INT_NPE_HI = IBM_RCEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,0); IF (INT_NPE_HI<1) CYCLE
            X1AXIS = VIND
            ALLOCATE(EP_TAG(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)); EP_TAG(:)=.FALSE.
            DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
               I = IBM_RCEDGE(IEDGE)%INT_IJK(IAXIS,INPE)
               J = IBM_RCEDGE(IEDGE)%INT_IJK(JAXIS,INPE)
               K = IBM_RCEDGE(IEDGE)%INT_IJK(KAXIS,INPE)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                     FLGX = (I >= ILO_FACE) .AND. (I <= IHI_FACE)
                     FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                     FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                     INNM = FLGX .AND. FLGY .AND. FLGZ
                     IF (INNM) THEN
                        NOM=NM; IIO=I; JJO=J; KKO=K
                     ELSE
                        CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XFACE(I),YCELL(J),ZCELL(K),NOM,IIO,JJO,KKO)
                     ENDIF
                     IF(NOM==0) EP_TAG(INPE) = .TRUE.
                     CALL ASSIGN_TO_FC_R
                  ENDIF
               CASE(JAXIS)
                  IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                     FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                     FLGY = (J >= JLO_FACE) .AND. (J <= JHI_FACE)
                     FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                     INNM = FLGX .AND. FLGY .AND. FLGZ
                     IF (INNM) THEN
                        NOM=NM; IIO=I; JJO=J; KKO=K
                     ELSE
                        CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YFACE(J),ZCELL(K),NOM,IIO,JJO,KKO)
                     ENDIF
                     IF(NOM==0) EP_TAG(INPE) = .TRUE.
                     CALL ASSIGN_TO_FC_R
                  ENDIF
               CASE(KAXIS)
                  IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                     FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                     FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                     FLGZ = (K >= KLO_FACE) .AND. (K <= KHI_FACE)
                     INNM = FLGX .AND. FLGY .AND. FLGZ
                     IF (INNM) THEN
                        NOM=NM; IIO=I; JJO=J; KKO=K
                     ELSE
                        CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YCELL(J),ZFACE(K),NOM,IIO,JJO,KKO)
                     ENDIF
                     IF(NOM==0) EP_TAG(INPE) = .TRUE.
                     CALL ASSIGN_TO_FC_R
                  ENDIF
               END SELECT
               IBM_RCEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INPE) = IJKFACE2(LOW_IND:HIGH_IND,I,J,K,X1AXIS)
            ENDDO
            ! Now restrict count on cut-face :
            IF(ANY(EP_TAG .EQV. .TRUE.)) CALL RESTRICT_EP(IBM_ETYPE_RCGAS)
            DEALLOCATE(EP_TAG)
            ! Compute derivative coefficients.
            CALL COMPUTE_DCOEF(IBM_ETYPE_RCGAS)
         ENDDO
      ENDDO
   ENDDO
   ! 2. IBEDGES:
   CC_STRESS_METHOD_IF : IF (CC_STRESS_METHOD) THEN
      DO IEDGE=1,MESHES(NM)%IBM_NIBEDGE
         DO ICD_SGN=-2,2
            IF(ICD_SGN==0) CYCLE
            DO EP=1,INT_N_EXT_PTS  ! External point for IEDGE
               DO VIND=IAXIS,KAXIS ! Velocity component U, V or W for external point EP
                  INT_NPE_HI = IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN); IF (INT_NPE_HI<1) CYCLE
                  INT_NPE_LO = IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
                  X1AXIS = VIND
                  ALLOCATE(EP_TAG(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)); EP_TAG(:)=.FALSE.
                  DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                     I = IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS,INPE)
                     J = IBM_IBEDGE(IEDGE)%INT_IJK(JAXIS,INPE)
                     K = IBM_IBEDGE(IEDGE)%INT_IJK(KAXIS,INPE)
                     SELECT CASE(X1AXIS)
                     CASE(IAXIS)
                        IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                           FLGX = (I >= ILO_FACE) .AND. (I <= IHI_FACE)
                           FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                           FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                           INNM = FLGX .AND. FLGY .AND. FLGZ
                           IF (INNM) THEN
                              NOM=NM; IIO=I; JJO=J; KKO=K
                           ELSE
                              CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XFACE(I),YCELL(J),ZCELL(K),NOM,IIO,JJO,KKO)
                           ENDIF
                           IF(NOM==0) EP_TAG(INPE) = .TRUE.
                           CALL ASSIGN_TO_FC_R
                        ENDIF
                     CASE(JAXIS)
                        IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                           FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                           FLGY = (J >= JLO_FACE) .AND. (J <= JHI_FACE)
                           FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                           INNM = FLGX .AND. FLGY .AND. FLGZ
                           IF (INNM) THEN
                              NOM=NM; IIO=I; JJO=J; KKO=K
                           ELSE
                              CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YFACE(J),ZCELL(K),NOM,IIO,JJO,KKO)
                           ENDIF
                           IF(NOM==0) EP_TAG(INPE) = .TRUE.
                           CALL ASSIGN_TO_FC_R
                        ENDIF
                     CASE(KAXIS)
                        IF (IJKFACE2(LOW_IND,I,J,K,X1AXIS) < 1 ) THEN
                           FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                           FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                           FLGZ = (K >= KLO_FACE) .AND. (K <= KHI_FACE)
                           INNM = FLGX .AND. FLGY .AND. FLGZ
                           IF (INNM) THEN
                              NOM=NM; IIO=I; JJO=J; KKO=K
                           ELSE
                              CALL SEARCH_OTHER_MESHES_FACE(NM,X1AXIS,XCELL(I),YCELL(J),ZFACE(K),NOM,IIO,JJO,KKO)
                           ENDIF
                           IF(NOM==0) EP_TAG(INPE) = .TRUE.
                           CALL ASSIGN_TO_FC_R
                        ENDIF
                     END SELECT
                     IBM_IBEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INPE) = IJKFACE2(LOW_IND:HIGH_IND,I,J,K,X1AXIS)
                  ENDDO
                  ! Now restrict count on cut-face :
                  IF(ANY(EP_TAG .EQV. .TRUE.)) CALL RESTRICT_EP(IBM_ETYPE_EP)
                  DEALLOCATE(EP_TAG)
               ENDDO
            ENDDO
         ENDDO
      ENDDO
   ENDIF CC_STRESS_METHOD_IF

   DEALLOCATE(IJKFACE2)

   ! Now Cell Variables:
   ALLOCATE(IJKCELL(LOW_IND:HIGH_IND,ISTR:IEND,JSTR:JEND,KSTR:KEND)); IJKCELL = IBM_UNDEFINED

   ! First Cut-cells:
   VIND = 0
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      I = CUT_CELL(ICC)%IJK(IAXIS)
      J = CUT_CELL(ICC)%IJK(JAXIS)
      K = CUT_CELL(ICC)%IJK(KAXIS)
      ! Don't count cut-cells inside an OBST:
      IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
      DO ICELL=0,CUT_CELL(ICC)%NCELL
         DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
            INT_NPE_LO = CUT_CELL(ICC)%INT_NPE(LOW_IND,VIND,EP,ICELL)
            INT_NPE_HI = CUT_CELL(ICC)%INT_NPE(HIGH_IND,VIND,EP,ICELL)
            X1AXIS = VIND
            ALLOCATE(EP_TAG(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)); EP_TAG(:)=.FALSE.
            DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
               I = CUT_CELL(ICC)%INT_IJK(IAXIS,INPE)
               J = CUT_CELL(ICC)%INT_IJK(JAXIS,INPE)
               K = CUT_CELL(ICC)%INT_IJK(KAXIS,INPE)
               ! If cell not counted yet:
               IF (IJKCELL(LOW_IND,I,J,K) < 1 ) THEN
                  FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                  FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                  FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                  INNM = FLGX .AND. FLGY .AND. FLGZ
                  IF (INNM) THEN
                     NOM=NM; IIO=I; JJO=J; KKO=K
                  ELSE
                     CALL SEARCH_OTHER_MESHES(XCELL(I),YCELL(J),ZCELL(K),NOM,IIO,JJO,KKO)
                  ENDIF
                  IF(NOM==0) EP_TAG(INPE) = .TRUE.
                  CALL ASSIGN_TO_CC_R
               ENDIF
               CUT_CELL(ICC)%INT_NOMIND(LOW_IND:HIGH_IND,INPE) = IJKCELL(LOW_IND:HIGH_IND,I,J,K)
            ENDDO
            ! Now restrict count on cut-face :
            IF(ANY(EP_TAG .EQV. .TRUE.)) CALL RESTRICT_EP(IBM_FTYPE_CCGAS)
            DEALLOCATE(EP_TAG)
         ENDDO
      ENDDO
   ENDDO

   ! INBOUNDARY cut-faces, cell centered vars:
   VIND = 0
   DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      IF (CUT_FACE(ICF)%STATUS /= IBM_INBOUNDARY) CYCLE
      I = CUT_FACE(ICF)%IJK(IAXIS)
      J = CUT_FACE(ICF)%IJK(JAXIS)
      K = CUT_FACE(ICF)%IJK(KAXIS)
      ! Don't count cut-cells inside an OBST:
      IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
      DO IFACE=1,CUT_FACE(ICF)%NFACE
         DO EP=1,INT_N_EXT_PTS  ! External point for face IFACE
            INT_NPE_LO = CUT_FACE(ICF)%INT_NPE(LOW_IND,VIND,EP,IFACE)
            INT_NPE_HI = CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
            X1AXIS = VIND
            ALLOCATE(EP_TAG(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)); EP_TAG(:)=.FALSE.
            DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
               I = CUT_FACE(ICF)%INT_IJK(IAXIS,INPE)
               J = CUT_FACE(ICF)%INT_IJK(JAXIS,INPE)
               K = CUT_FACE(ICF)%INT_IJK(KAXIS,INPE)
               ! If cell not counted yet:
               IF (IJKCELL(LOW_IND,I,J,K) < 1 ) THEN
                  FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                  FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                  FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                  INNM = FLGX .AND. FLGY .AND. FLGZ
                  IF (INNM) THEN
                     NOM=NM; IIO=I; JJO=J; KKO=K
                  ELSE
                     CALL SEARCH_OTHER_MESHES(XCELL(I),YCELL(J),ZCELL(K),NOM,IIO,JJO,KKO)
                  ENDIF
                  IF(NOM==0) EP_TAG(INPE) = .TRUE.
                  CALL ASSIGN_TO_CC_R
               ENDIF
               CUT_FACE(ICF)%INT_NOMIND(LOW_IND:HIGH_IND,INPE) = IJKCELL(LOW_IND:HIGH_IND,I,J,K)
            ENDDO
            ! Now restrict count on cut-face :
            IF(ANY(EP_TAG .EQV. .TRUE.)) CALL RESTRICT_EP(IBM_FTYPE_CFINB)
            DEALLOCATE(EP_TAG)
         ENDDO
      ENDDO
   ENDDO

   ! 2. Cell-centered variables for IBEDGES:
   CC_STRESS_METHOD_IF2 : IF (CC_STRESS_METHOD) THEN
      VIND = 0
      DO IEDGE=1,MESHES(NM)%IBM_NIBEDGE
         DO ICD_SGN=-2,2
            IF(ICD_SGN==0) CYCLE
            DO EP=1,INT_N_EXT_PTS  ! External point for IEDGE
               INT_NPE_HI = IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN); IF (INT_NPE_HI<1) CYCLE
               INT_NPE_LO = IBM_IBEDGE(IEDGE)%INT_NPE(LOW_IND,VIND,EP,ICD_SGN)
               X1AXIS = VIND
               ALLOCATE(EP_TAG(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)); EP_TAG(:)=.FALSE.
               DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
                  I = IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS,INPE)
                  J = IBM_IBEDGE(IEDGE)%INT_IJK(JAXIS,INPE)
                  K = IBM_IBEDGE(IEDGE)%INT_IJK(KAXIS,INPE)
                  ! If cell not counted yet:
                  IF (IJKCELL(LOW_IND,I,J,K) < 1 ) THEN
                     FLGX = (I >= ILO_CELL) .AND. (I <= IHI_CELL)
                     FLGY = (J >= JLO_CELL) .AND. (J <= JHI_CELL)
                     FLGZ = (K >= KLO_CELL) .AND. (K <= KHI_CELL)
                     INNM = FLGX .AND. FLGY .AND. FLGZ
                     IF (INNM) THEN
                        NOM=NM; IIO=I; JJO=J; KKO=K
                     ELSE
                        CALL SEARCH_OTHER_MESHES(XCELL(I),YCELL(J),ZCELL(K),NOM,IIO,JJO,KKO)
                     ENDIF
                     IF(NOM==0) EP_TAG(INPE) = .TRUE.
                     CALL ASSIGN_TO_CC_R
                  ENDIF
                  IBM_IBEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INPE) = IJKCELL(LOW_IND:HIGH_IND,I,J,K)
               ENDDO
               ! Now restrict count on cut-face :
               IF(ANY(EP_TAG .EQV. .TRUE.)) CALL RESTRICT_EP(IBM_ETYPE_EP)
               DEALLOCATE(EP_TAG)
            ENDDO
         ENDDO
      ENDDO
   ENDIF CC_STRESS_METHOD_IF2

   ! Add ghost-cells which are of type IBM_CUTCFE or next to one cell type IBM_CUTCFE:
   ! First record size of interpolation cells to be reveiced from OMESHES:
   DO NOM=1,NMESHES
      OMESH(NOM)%NCC_INT_R=OMESH(NOM)%NFCC_R(2)
   ENDDO
   ! Now loop INTERPOLATED WALL_CELLs:
   EXT_WALL_LOOP : DO IW=1,N_EXTERNAL_WALL_CELLS

      WC=>WALL(IW)
      EWC=>EXTERNAL_WALL(IW)
      IF (WC%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY) CYCLE EXT_WALL_LOOP

      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK
      NOM = EWC%NOM
      IF (NOM <= 0) CYCLE EXT_WALL_LOOP

      IF(ANY(CCVAR(II-1:II+1,JJ-1:JJ+1,KK-1:KK+1,IBM_CGSC)==IBM_CUTCFE)) THEN
         DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
            DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
               DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
                OMESH(NOM)%NFCC_R(2)= OMESH(NOM)%NFCC_R(2) + 1
                SIZE_REC=SIZE(OMESH(NOM)%IIO_CC_R,DIM=1)
                IF(OMESH(NOM)%NFCC_R(2) > SIZE_REC) THEN
                    ALLOCATE(IIO_CC_R_AUX(SIZE_REC),JJO_CC_R_AUX(SIZE_REC),KKO_CC_R_AUX(SIZE_REC));
                    IIO_CC_R_AUX(1:SIZE_REC)=OMESH(NOM)%IIO_CC_R(1:SIZE_REC)
                    JJO_CC_R_AUX(1:SIZE_REC)=OMESH(NOM)%JJO_CC_R(1:SIZE_REC)
                    KKO_CC_R_AUX(1:SIZE_REC)=OMESH(NOM)%KKO_CC_R(1:SIZE_REC)
                    DEALLOCATE(OMESH(NOM)%IIO_CC_R); ALLOCATE(OMESH(NOM)%IIO_CC_R(SIZE_REC+DELTA_FC))
                    OMESH(NOM)%IIO_CC_R(1:SIZE_REC)=IIO_CC_R_AUX(1:SIZE_REC)
                    DEALLOCATE(OMESH(NOM)%JJO_CC_R); ALLOCATE(OMESH(NOM)%JJO_CC_R(SIZE_REC+DELTA_FC))
                    OMESH(NOM)%JJO_CC_R(1:SIZE_REC)=JJO_CC_R_AUX(1:SIZE_REC)
                    DEALLOCATE(OMESH(NOM)%KKO_CC_R); ALLOCATE(OMESH(NOM)%KKO_CC_R(SIZE_REC+DELTA_FC))
                    OMESH(NOM)%KKO_CC_R(1:SIZE_REC)=KKO_CC_R_AUX(1:SIZE_REC)
                    DEALLOCATE(IIO_CC_R_AUX,JJO_CC_R_AUX,KKO_CC_R_AUX)
                ENDIF
                OMESH(NOM)%IIO_CC_R(OMESH(NOM)%NFCC_R(2)) = IIO
                OMESH(NOM)%JJO_CC_R(OMESH(NOM)%NFCC_R(2)) = JJO
                OMESH(NOM)%KKO_CC_R(OMESH(NOM)%NFCC_R(2)) = KKO
               ENDDO
            ENDDO
         ENDDO
       ENDIF
   ENDDO EXT_WALL_LOOP
   DEALLOCATE(IJKCELL)

   ! WRITE(LU_ERR,*) ' MY_RANK,   NM,   NOM,   OMESH(NOM)%NFC_R,  OMESH(NOM)%NCC_R'
   ! DO NOM=1,NMESHES
   !    WRITE(LU_ERR,*) MY_RANK,NM,NOM,OMESH(NOM)%NFC_R,OMESH(NOM)%NCC_R
   ! ENDDO
   ! WRITE(LU_ERR,*) ' '

   ! Quality control:
   ! print*, 'MESHES(NM)%IBM_NRCELL_H=',MESHES(NM)%IBM_NRCELL_H
   ! IRC=176 ! Last entry for mesh 24x24x24 on sphre_air_demo_1.fds
   ! print*,' '
   ! print*,'RCELL=',IRC
   ! print*,'IJK=',MESHES(NM)%IBM_RCELL_H(IRC)%IJK(IAXIS:KAXIS)
   ! print*,'NCCELL=',MESHES(NM)%IBM_RCELL_H(IRC)%NCCELL
   ! print*,'CELL_LIST=',MESHES(NM)%IBM_RCELL_H(IRC)%CELL_LIST(1:MESHES(NM)%IBM_RCELL_H(IRC)%NCCELL)
   ! print*,'INBFC_CARTCEN(1:3)=',MESHES(NM)%IBM_RCELL_H(IRC)%INBFC_CARTCEN(1:3)
   ! print*,'INTCOEF_CARTCEN(1:5)=',MESHES(NM)%IBM_RCELL_H(IRC)%INTCOEF_CARTCEN(1:5)


   ! Deallocate arrays:
   ! Face centered positions and cell sizes:
   IF (ALLOCATED(XFACE)) DEALLOCATE(XFACE)
   IF (ALLOCATED(YFACE)) DEALLOCATE(YFACE)
   IF (ALLOCATED(ZFACE)) DEALLOCATE(ZFACE)
   IF (ALLOCATED(DXFACE)) DEALLOCATE(DXFACE)
   IF (ALLOCATED(DYFACE)) DEALLOCATE(DYFACE)
   IF (ALLOCATED(DZFACE)) DEALLOCATE(DZFACE)

   ! Cell centered positions and cell sizes:
   IF (ALLOCATED(XCELL)) DEALLOCATE(XCELL)
   IF (ALLOCATED(YCELL)) DEALLOCATE(YCELL)
   IF (ALLOCATED(ZCELL)) DEALLOCATE(ZCELL)
   IF (ALLOCATED(DXCELL)) DEALLOCATE(DXCELL)
   IF (ALLOCATED(DYCELL)) DEALLOCATE(DYCELL)
   IF (ALLOCATED(DZCELL)) DEALLOCATE(DZCELL)

ENDDO MESHES_LOOP2

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START_LOOP,' sec.'
   WRITE(LU_SETCC,'(A)') &
   ' - Into FILL_IJKO_INTERP_STENCILS MPI communication..'
   CALL CPU_TIME(CPUTIME_START_LOOP)
ENDIF

! Finally Exchange info on messages to send among MPI processes:
! Populates OMESH(NOM)% : NFCC_S, IIO_FCC_S, JJO_FCC_S, KKO_FCC_S, AXS_FCC_S
CALL FILL_IJKO_INTERP_STENCILS

! Fill unpacking arrays
CALL CC_EXCHANGE_UNPACKING_ARRAYS


IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') '   Done FILL_IJKO_INTERP_STENCILS. Time taken : ',CPUTIME-CPUTIME_START_LOOP,' sec.'
ENDIF

IF (DEBUG_IBM_INTERPOLATION) THEN
   ! Write IBSEGS normals:
   DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      WRITE(MSEGS_FILE,'(A,A,I4.4,A)') TRIM(CHID),'_ibsegns_mesh_',NM,'.dat'
      LU_DB_CCIB = GET_FILE_NUMBER()
      OPEN(LU_DB_CCIB,FILE=TRIM(MSEGS_FILE),STATUS='UNKNOWN')
      IF (.NOT.CC_STRESS_METHOD) THEN
         DO ECOUNT=1,MESHES(NM)%IBM_NIBEDGE
            WRITE(LU_DB_CCIB,'(5F13.8)') MESHES(NM)%IBM_IBEDGE(ECOUNT)%INT_NOUT(IAXIS:KAXIS,0),&
                                           MESHES(NM)%IBM_IBEDGE(ECOUNT)%INT_XN(0:1,0)
         ENDDO
      ELSE
         DO ECOUNT=1,MESHES(NM)%IBM_NIBEDGE
            WRITE(LU_DB_CCIB,'(5F13.8)') 0.,0.,0.,0.,0.
         ENDDO
      ENDIF
      CLOSE(LU_DB_CCIB)
   ENDDO
ENDIF

RETURN

CONTAINS

! ----------------------------- COMPUTE_DCOEF ----------------------------------

SUBROUTINE COMPUTE_DCOEF(DATA_IN)

INTEGER, INTENT(IN) :: DATA_IN

INTEGER, ALLOCATABLE, DIMENSION(:,:,:)   :: MASK_IJK
REAL(EB),ALLOCATABLE, DIMENSION(:,:,:)   :: N2
INTEGER  :: ILO,IHI,JLO,JHI,KLO,KHI
INTEGER  :: II,JJ,KK,DUMAXIS,COUNT,NEDGI
REAL(EB),ALLOCATABLE, DIMENSION(:,:,:,:) :: RAW_DCOEF
REAL(EB) :: XYZ_LOHI(LOW_IND:HIGH_IND,IAXIS:KAXIS),XYZE(IAXIS:KAXIS),X_P(IAXIS:KAXIS)
LOGICAL :: EVAL=.FALSE.

IF(DATA_IN==IBM_ETYPE_RCGAS) THEN
   IF(ALLOCATED(IBM_RCEDGE(IEDGE)%INT_DCOEF)) EVAL = .TRUE.
ELSE
   IF(ALLOCATED(CUT_FACE(ICF)%INT_DCOEF)) EVAL = .TRUE.
ENDIF

IF(EVAL) THEN
   IF(DATA_IN==IBM_ETYPE_RCGAS) THEN
      NPE_COUNT = IBM_RCEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,0)
      IF(NPE_COUNT==0) RETURN
      ! Zero DCOEF if any of the box edges vertices is missing:
      ILO = MINVAL(IBM_RCEDGE(IEDGE)%INT_IJK(IAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      IHI = MAXVAL(IBM_RCEDGE(IEDGE)%INT_IJK(IAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      JLO = MINVAL(IBM_RCEDGE(IEDGE)%INT_IJK(JAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      JHI = MAXVAL(IBM_RCEDGE(IEDGE)%INT_IJK(JAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      KLO = MINVAL(IBM_RCEDGE(IEDGE)%INT_IJK(KAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      KHI = MAXVAL(IBM_RCEDGE(IEDGE)%INT_IJK(KAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
   ELSEIF(DATA_IN==IBM_ETYPE_SCINB) THEN
      NPE_COUNT = IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,0)
      IF(NPE_COUNT==0) RETURN
      ! Zero DCOEF if any of the box edges vertices is missing:
      ILO = MINVAL(IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      IHI = MAXVAL(IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      JLO = MINVAL(IBM_IBEDGE(IEDGE)%INT_IJK(JAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      JHI = MAXVAL(IBM_IBEDGE(IEDGE)%INT_IJK(JAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      KLO = MINVAL(IBM_IBEDGE(IEDGE)%INT_IJK(KAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      KHI = MAXVAL(IBM_IBEDGE(IEDGE)%INT_IJK(KAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
   ELSE
      NPE_COUNT = CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE)
      IF(NPE_COUNT==0) RETURN
      ! Zero DCOEF if any of the box edges vertices is missing:
      ILO = MINVAL(CUT_FACE(ICF)%INT_IJK(IAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      IHI = MAXVAL(CUT_FACE(ICF)%INT_IJK(IAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      JLO = MINVAL(CUT_FACE(ICF)%INT_IJK(JAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      JHI = MAXVAL(CUT_FACE(ICF)%INT_IJK(JAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      KLO = MINVAL(CUT_FACE(ICF)%INT_IJK(KAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
      KHI = MAXVAL(CUT_FACE(ICF)%INT_IJK(KAXIS,INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT))
   ENDIF

   ALLOCATE(INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI))
   INT_DCOEF = 0._EB
   ALLOCATE(MASK_IJK(ILO:IHI,JLO:JHI,KLO:KHI)); MASK_IJK = 0
   ALLOCATE(RAW_DCOEF(IAXIS:KAXIS,ILO:IHI,JLO:JHI,KLO:KHI)); RAW_DCOEF=0._EB;
   ALLOCATE(N2(ILO:IHI,JLO:JHI,KLO:KHI))

   IF(VIND==IAXIS) THEN
      XYZ_LOHI(LOW_IND:HIGH_IND,IAXIS) = (/ XFACE(ILO), XFACE(IHI) /)
   ELSE
      XYZ_LOHI(LOW_IND:HIGH_IND,IAXIS) = (/ XCELL(ILO), XCELL(IHI) /)
   ENDIF
   IF(VIND==JAXIS) THEN
      XYZ_LOHI(LOW_IND:HIGH_IND,JAXIS) = (/ YFACE(JLO), YFACE(JHI) /)
   ELSE
      XYZ_LOHI(LOW_IND:HIGH_IND,JAXIS) = (/ YCELL(JLO), YCELL(JHI) /)
   ENDIF
   IF(VIND==KAXIS) THEN
      XYZ_LOHI(LOW_IND:HIGH_IND,KAXIS) = (/ ZFACE(KLO), ZFACE(KHI) /)
   ELSE
      XYZ_LOHI(LOW_IND:HIGH_IND,KAXIS) = (/ ZCELL(KLO), ZCELL(KHI) /)
   ENDIF

   ! Define external point:
   IF(DATA_IN==IBM_ETYPE_RCGAS) THEN
      XYZE(IAXIS:KAXIS) = IBM_RCEDGE(IEDGE)%INT_XYZBF(IAXIS:KAXIS,0) + &
      IBM_RCEDGE(IEDGE)%INT_XN(EP,0)*IBM_RCEDGE(IEDGE)%INT_NOUT(IAXIS:KAXIS,0)
   ELSEIF(DATA_IN==IBM_ETYPE_SCINB) THEN
      XYZE(IAXIS:KAXIS) = IBM_IBEDGE(IEDGE)%INT_XYZBF(IAXIS:KAXIS,0) + &
      IBM_IBEDGE(IEDGE)%INT_XN(EP,0)*IBM_IBEDGE(IEDGE)%INT_NOUT(IAXIS:KAXIS,0)
   ELSE
      XYZE(IAXIS:KAXIS) = CUT_FACE(ICF)%INT_XYZBF(IAXIS:KAXIS,IFACE) + &
      CUT_FACE(ICF)%INT_XN(EP,IFACE)*CUT_FACE(ICF)%INT_NOUT(IAXIS:KAXIS,IFACE)
   ENDIF

   ! Masked Trilinear interpolation coefficients:
   X_P(IAXIS:KAXIS) = 0._EB
   DO DUMAXIS=IAXIS,KAXIS
      IF(ABS(XYZ_LOHI(HIGH_IND,DUMAXIS)-XYZ_LOHI(LOW_IND,DUMAXIS)) > TWO_EPSILON_EB) &
      X_P(DUMAXIS) = (XYZE(DUMAXIS)-XYZ_LOHI(LOW_IND,DUMAXIS)) / &
                     (XYZ_LOHI(HIGH_IND,DUMAXIS)-XYZ_LOHI(LOW_IND,DUMAXIS))
   ENDDO

   IF(DATA_IN==IBM_ETYPE_RCGAS) THEN
      DO INPE=INT_NPE_LO+1,INT_NPE_LO+NPE_COUNT
      MASK_IJK(IBM_RCEDGE(IEDGE)%INT_IJK(IAXIS,INPE),IBM_RCEDGE(IEDGE)%INT_IJK(JAXIS,INPE),IBM_RCEDGE(IEDGE)%INT_IJK(KAXIS,INPE))=1
      ENDDO
   ELSEIF(DATA_IN==IBM_ETYPE_SCINB) THEN
      DO INPE=INT_NPE_LO+1,INT_NPE_LO+NPE_COUNT
      MASK_IJK(IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS,INPE),IBM_IBEDGE(IEDGE)%INT_IJK(JAXIS,INPE),IBM_IBEDGE(IEDGE)%INT_IJK(KAXIS,INPE))=1
      ENDDO
   ELSE
      DO INPE=INT_NPE_LO+1,INT_NPE_LO+NPE_COUNT
      MASK_IJK(CUT_FACE(ICF)%INT_IJK(IAXIS,INPE),CUT_FACE(ICF)%INT_IJK(JAXIS,INPE),CUT_FACE(ICF)%INT_IJK(KAXIS,INPE))=1
      ENDDO
   ENDIF

   ! d/dx : First look at which Points are present as both ends of X edges:
   NEDGI = 0
   DO KK = KLO,KHI
      DO JJ = JLO,JHI
         IF(MASK_IJK(ILO,JJ,KK) == 1 .AND. MASK_IJK(IHI,JJ,KK) == 1) THEN ! Both points on edge are populated:
            NEDGI = NEDGI + 1
            RAW_DCOEF(IAXIS,IHI,JJ,KK) = 1._EB/DXCELL(ILO)
            RAW_DCOEF(IAXIS,ILO,JJ,KK) =-1._EB/DXCELL(ILO)
         ENDIF
      ENDDO
   ENDDO
   ! Regarding the number of Edges interpolate:
   IF (NEDGI > 0 .AND. NEDGI < 4) THEN ! Simple average:
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               RAW_DCOEF(IAXIS,II,JJ,KK) = RAW_DCOEF(IAXIS,II,JJ,KK)/REAL(NEDGI,EB)
            ENDDO
         ENDDO
      ENDDO
   ELSE ! Bilinear in y, z directions:
      N2(ILO:IHI,JLO,KLO) = (1._EB-X_P(JAXIS))*(1._EB-X_P(KAXIS))
      N2(ILO:IHI,JHI,KLO) = (      X_P(JAXIS))*(1._EB-X_P(KAXIS))
      N2(ILO:IHI,JLO,KHI) = (1._EB-X_P(JAXIS))*(      X_P(KAXIS))
      N2(ILO:IHI,JHI,KHI) = (      X_P(JAXIS))*(      X_P(KAXIS))
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               RAW_DCOEF(IAXIS,II,JJ,KK) = N2(II,JJ,KK)*RAW_DCOEF(IAXIS,II,JJ,KK)
            ENDDO
         ENDDO
      ENDDO
   ENDIF
   ! d/dy : First look at which Points are present as both ends of Y edges:
   NEDGI = 0
   DO KK = KLO,KHI
      DO II = ILO,IHI
         IF(MASK_IJK(II,JLO,KK) == 1 .AND. MASK_IJK(II,JHI,KK) == 1) THEN ! Both points on edge are populated:
            NEDGI = NEDGI + 1
            RAW_DCOEF(JAXIS,II,JHI,KK) = 1._EB/DYCELL(JLO)
            RAW_DCOEF(JAXIS,II,JLO,KK) =-1._EB/DYCELL(JLO)
         ENDIF
      ENDDO
   ENDDO
   ! Regarding the number of Edges interpolate:
   IF (NEDGI > 0 .AND. NEDGI < 4) THEN ! Simple average:
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               RAW_DCOEF(JAXIS,II,JJ,KK) = RAW_DCOEF(JAXIS,II,JJ,KK)/REAL(NEDGI,EB)
            ENDDO
         ENDDO
      ENDDO
   ELSE ! Bilinear in x, z directions:
      N2(ILO,JLO:JHI,KLO) = (1._EB-X_P(IAXIS))*(1._EB-X_P(KAXIS))
      N2(IHI,JLO:JHI,KLO) = (      X_P(IAXIS))*(1._EB-X_P(KAXIS))
      N2(ILO,JLO:JHI,KHI) = (1._EB-X_P(IAXIS))*(      X_P(KAXIS))
      N2(IHI,JLO:JHI,KHI) = (      X_P(IAXIS))*(      X_P(KAXIS))
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               RAW_DCOEF(JAXIS,II,JJ,KK) = N2(II,JJ,KK)*RAW_DCOEF(JAXIS,II,JJ,KK)
            ENDDO
         ENDDO
      ENDDO
   ENDIF
   ! d/dz : First look at which Points are present as both ends of Z edges:
   NEDGI = 0
   DO JJ = JLO,JHI
      DO II = ILO,IHI
         IF(MASK_IJK(II,JJ,KLO) == 1 .AND. MASK_IJK(II,JJ,KHI) == 1) THEN ! Both points on edge are populated:
            NEDGI = NEDGI + 1
            RAW_DCOEF(KAXIS,II,JJ,KHI) = 1._EB/DZCELL(KLO)
            RAW_DCOEF(KAXIS,II,JJ,KLO) =-1._EB/DZCELL(KLO)
         ENDIF
      ENDDO
   ENDDO
   ! Regarding the number of Edges interpolate:
   IF (NEDGI > 0 .AND. NEDGI < 4) THEN ! Simple average:
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               RAW_DCOEF(KAXIS,II,JJ,KK) = RAW_DCOEF(KAXIS,II,JJ,KK)/REAL(NEDGI,EB)
            ENDDO
         ENDDO
      ENDDO
   ELSE ! Bilinear in x, y directions:
      N2(ILO,JLO,KLO:KHI) = (1._EB-X_P(IAXIS))*(1._EB-X_P(JAXIS))
      N2(IHI,JLO,KLO:KHI) = (      X_P(IAXIS))*(1._EB-X_P(JAXIS))
      N2(ILO,JHI,KLO:KHI) = (1._EB-X_P(IAXIS))*(      X_P(JAXIS))
      N2(IHI,JHI,KLO:KHI) = (      X_P(IAXIS))*(      X_P(JAXIS))
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               RAW_DCOEF(KAXIS,II,JJ,KK) = N2(II,JJ,KK)*RAW_DCOEF(KAXIS,II,JJ,KK)
            ENDDO
         ENDDO
      ENDDO
   ENDIF
   ! Finally populate INT_DCOEF:
   COUNT = 0
   DO KK = KLO,KHI
      DO JJ = JLO,JHI
         DO II = ILO,IHI
            IF(MASK_IJK(II,JJ,KK) == 1) THEN
               COUNT = COUNT + 1
               INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+COUNT) = RAW_DCOEF(IAXIS:KAXIS,II,JJ,KK)
            ENDIF
         ENDDO
      ENDDO
   ENDDO
   IF(DATA_IN==IBM_ETYPE_RCGAS) THEN
      IBM_RCEDGE(IEDGE)%INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
      INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   ELSEIF(DATA_IN==IBM_ETYPE_SCINB) THEN
      IBM_IBEDGE(IEDGE)%INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
      INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   ELSE
      CUT_FACE(ICF)%INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
      INT_DCOEF(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   ENDIF
   DEALLOCATE(INT_DCOEF,MASK_IJK,N2,RAW_DCOEF)
ENDIF

RETURN
END SUBROUTINE COMPUTE_DCOEF

! ------------------------------ RESTRICT_EP ----------------------------------

SUBROUTINE RESTRICT_EP(CFRC_FLG)

INTEGER, INTENT(IN) :: CFRC_FLG

REAL(EB):: PROD_COEF

! Apply restriction to stencil points with NOM>0:
ALLOCATE(INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI),   &
         INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI),              &
         INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI))
INT_IJK = IBM_UNDEFINED; INT_COEF = 0._EB; INT_NOMIND = IBM_UNDEFINED
NPE_COUNT = 0
PROD_COEF= 0._EB
SELECT CASE(CFRC_FLG)
CASE(IBM_FTYPE_CFGAS,IBM_FTYPE_CFINB)
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      IF(.NOT.EP_TAG(INPE)) THEN ! Point has a NOM /= 0
         NPE_COUNT = NPE_COUNT + 1
         INT_IJK(IAXIS:KAXIS,INT_NPE_LO+NPE_COUNT) = CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,INPE)
         INT_COEF(INT_NPE_LO+NPE_COUNT) = CUT_FACE(ICF)%INT_COEF(INPE)
         PROD_COEF = PROD_COEF + INT_COEF(INT_NPE_LO+NPE_COUNT)
         INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+NPE_COUNT) = &
         CUT_FACE(ICF)%INT_NOMIND(LOW_IND:HIGH_IND,INPE)
      ENDIF
   ENDDO
   IF (ABS(PROD_COEF) < TWO_EPSILON_EB) THEN ! Any viable points throught EP_TAG have been discarded by IJKFACE2.
      INT_IJK=IBM_UNDEFINED; INT_COEF=0._EB; INT_NOMIND=IBM_UNDEFINED; NPE_COUNT=0
   ENDIF
   CUT_FACE(ICF)%INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   CUT_FACE(ICF)%INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   CUT_FACE(ICF)%INT_NPE(HIGH_IND,VIND,EP,IFACE) = NPE_COUNT

   IF (NPE_COUNT > 0) &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT) = INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT)/PROD_COEF

   CUT_FACE(ICF)%INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)

CASE(IBM_ETYPE_RCGAS)
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      IF(.NOT.EP_TAG(INPE)) THEN ! Point has a NOM /= 0
         NPE_COUNT = NPE_COUNT + 1
         INT_IJK(IAXIS:KAXIS,INT_NPE_LO+NPE_COUNT) = IBM_RCEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,INPE)
         INT_COEF(INT_NPE_LO+NPE_COUNT) = IBM_RCEDGE(IEDGE)%INT_COEF(INPE)
         PROD_COEF = PROD_COEF + INT_COEF(INT_NPE_LO+NPE_COUNT)
         INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+NPE_COUNT) = &
         IBM_RCEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INPE)
      ENDIF
   ENDDO
   IF (ABS(PROD_COEF) < TWO_EPSILON_EB) THEN ! Any viable points throught EP_TAG have been discarded by IJKFACE2.
      INT_IJK=IBM_UNDEFINED; INT_COEF=0._EB; INT_NOMIND=IBM_UNDEFINED; NPE_COUNT=0
   ENDIF
   IBM_RCEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   IBM_RCEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   IBM_RCEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,0) = NPE_COUNT

   IF (NPE_COUNT > 0) &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT) = INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT)/PROD_COEF

   IBM_RCEDGE(IEDGE)%INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)

CASE(IBM_ETYPE_SCINB)
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      IF(.NOT.EP_TAG(INPE)) THEN ! Point has a NOM /= 0
         NPE_COUNT = NPE_COUNT + 1
         INT_IJK(IAXIS:KAXIS,INT_NPE_LO+NPE_COUNT) = IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,INPE)
         INT_COEF(INT_NPE_LO+NPE_COUNT) = IBM_IBEDGE(IEDGE)%INT_COEF(INPE)
         PROD_COEF = PROD_COEF + INT_COEF(INT_NPE_LO+NPE_COUNT)
         INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+NPE_COUNT) = &
         IBM_IBEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INPE)
      ENDIF
   ENDDO
   IF (ABS(PROD_COEF) < TWO_EPSILON_EB) THEN ! Any viable points throught EP_TAG have been discarded by IJKFACE2.
      INT_IJK=IBM_UNDEFINED; INT_COEF=0._EB; INT_NOMIND=IBM_UNDEFINED; NPE_COUNT=0
   ENDIF
   IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   IBM_IBEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,0) = NPE_COUNT

   IF (NPE_COUNT > 0) &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT) = INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT)/PROD_COEF

   IBM_IBEDGE(IEDGE)%INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)

CASE(IBM_ETYPE_EP)
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      IF(.NOT.EP_TAG(INPE)) THEN ! Point has a NOM /= 0
         NPE_COUNT = NPE_COUNT + 1
         INT_IJK(IAXIS:KAXIS,INT_NPE_LO+NPE_COUNT) = IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,INPE)
         INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+NPE_COUNT) = &
         IBM_IBEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INPE)
         INT_COEF(INT_NPE_LO+NPE_COUNT) = IBM_IBEDGE(IEDGE)%INT_DCOEF(INPE,1)
      ENDIF
   ENDDO
   IBM_IBEDGE(IEDGE)%INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   IBM_IBEDGE(IEDGE)%INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   IBM_IBEDGE(IEDGE)%INT_DCOEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI,1) = INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   IBM_IBEDGE(IEDGE)%INT_NPE(HIGH_IND,VIND,EP,ICD_SGN) = NPE_COUNT

CASE(IBM_FTYPE_RCGAS) ! Skip.
CASE(IBM_FTYPE_CCGAS)
   DO INPE=INT_NPE_LO+1,INT_NPE_LO+INT_NPE_HI
      IF(.NOT.EP_TAG(INPE)) THEN ! Point has a NOM /= 0
         NPE_COUNT = NPE_COUNT + 1
         INT_IJK(IAXIS:KAXIS,INT_NPE_LO+NPE_COUNT) = CUT_CELL(ICC)%INT_IJK(IAXIS:KAXIS,INPE)
         INT_COEF(INT_NPE_LO+NPE_COUNT) = CUT_CELL(ICC)%INT_COEF(INPE)
         PROD_COEF = PROD_COEF + INT_COEF(INT_NPE_LO+NPE_COUNT)
         INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+NPE_COUNT) = &
         CUT_CELL(ICC)%INT_NOMIND(LOW_IND:HIGH_IND,INPE)
      ENDIF
   ENDDO
   IF (ABS(PROD_COEF) < TWO_EPSILON_EB) THEN ! Any viable points throught EP_TAG have been discarded by IJKCELL.
      INT_IJK=IBM_UNDEFINED; INT_COEF=0._EB; INT_NOMIND=IBM_UNDEFINED; NPE_COUNT=0
   ENDIF
   CUT_CELL(ICC)%INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_IJK(IAXIS:KAXIS,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   CUT_CELL(ICC)%INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_NOMIND(LOW_IND:HIGH_IND,INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)
   CUT_CELL(ICC)%INT_NPE(HIGH_IND,VIND,EP,ICELL) = NPE_COUNT

   IF (NPE_COUNT > 0) &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT) = INT_COEF(INT_NPE_LO+1:INT_NPE_LO+NPE_COUNT)/PROD_COEF

   CUT_CELL(ICC)%INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI) = &
   INT_COEF(INT_NPE_LO+1:INT_NPE_LO+INT_NPE_HI)

END SELECT

DEALLOCATE(INT_IJK,INT_NOMIND,INT_COEF)

RETURN
END SUBROUTINE RESTRICT_EP

! ------------------------------- GET_DELN ------------------------------------

SUBROUTINE GET_DELN(FCTN_IN,DELN,DXLOC,DYLOC,DZLOC,NVEC,CLOSE_PT)

REAL(EB), INTENT(IN) :: FCTN_IN,DXLOC,DYLOC,DZLOC
REAL(EB), OPTIONAL, INTENT(IN) :: NVEC(MAX_DIM)
LOGICAL, OPTIONAL, INTENT(IN) :: CLOSE_PT
REAL(EB), INTENT(OUT) :: DELN

! Local Variables:
REAL(EB) :: FCTN
FCTN = FCTN_IN
IF (PRESENT(NVEC)) THEN
   IF( .NOT.PRESENT(CLOSE_PT) .AND. (ABS(NVEC(IAXIS))>GEOMEPS) .AND. &
   (ABS(NVEC(JAXIS))>GEOMEPS) .AND. (ABS(NVEC(KAXIS))>GEOMEPS)) FCTN=SQRT(3._EB)
   ! IF(PRESENT(CLOSE_PT)) THEN
   !    IF(CLOSE_PT) FCTN = 1._EB
   ! ENDIF
   DELN = FCTN*(DXLOC*ABS(NVEC(IAXIS))+DYLOC*ABS(NVEC(JAXIS))+DZLOC*ABS(NVEC(KAXIS)))
ELSE
   DELN = SQRT(DXLOC**2._EB+DYLOC**2._EB+DZLOC**2._EB)
ENDIF
RETURN
END SUBROUTINE GET_DELN

! ---------------------------- ASSIGN_TO_CC_R ---------------------------------

SUBROUTINE ASSIGN_TO_CC_R

 IF (NOM > 0) THEN ! Add to IIO_FC_R,JJO_FC_R,KKO_FC_R,AXIS_FC_R list,
                   ! and add 1 to NFC_R for OMESH(NOM).
    ! Use Automatic reallocation:
    OMESH(NOM)%NFCC_R(2)= OMESH(NOM)%NFCC_R(2) + 1
    SIZE_REC=SIZE(OMESH(NOM)%IIO_CC_R,DIM=1)
    IF(OMESH(NOM)%NFCC_R(2) > SIZE_REC) THEN
        ALLOCATE(IIO_CC_R_AUX(SIZE_REC),JJO_CC_R_AUX(SIZE_REC),KKO_CC_R_AUX(SIZE_REC));
        IIO_CC_R_AUX(1:SIZE_REC)=OMESH(NOM)%IIO_CC_R(1:SIZE_REC)
        JJO_CC_R_AUX(1:SIZE_REC)=OMESH(NOM)%JJO_CC_R(1:SIZE_REC)
        KKO_CC_R_AUX(1:SIZE_REC)=OMESH(NOM)%KKO_CC_R(1:SIZE_REC)
        DEALLOCATE(OMESH(NOM)%IIO_CC_R); ALLOCATE(OMESH(NOM)%IIO_CC_R(SIZE_REC+DELTA_FC))
        OMESH(NOM)%IIO_CC_R(1:SIZE_REC)=IIO_CC_R_AUX(1:SIZE_REC)
        DEALLOCATE(OMESH(NOM)%JJO_CC_R); ALLOCATE(OMESH(NOM)%JJO_CC_R(SIZE_REC+DELTA_FC))
        OMESH(NOM)%JJO_CC_R(1:SIZE_REC)=JJO_CC_R_AUX(1:SIZE_REC)
        DEALLOCATE(OMESH(NOM)%KKO_CC_R); ALLOCATE(OMESH(NOM)%KKO_CC_R(SIZE_REC+DELTA_FC))
        OMESH(NOM)%KKO_CC_R(1:SIZE_REC)=KKO_CC_R_AUX(1:SIZE_REC)
        DEALLOCATE(IIO_CC_R_AUX,JJO_CC_R_AUX,KKO_CC_R_AUX)
    ENDIF
    OMESH(NOM)%IIO_CC_R(OMESH(NOM)%NFCC_R(2)) = IIO
    OMESH(NOM)%JJO_CC_R(OMESH(NOM)%NFCC_R(2)) = JJO
    OMESH(NOM)%KKO_CC_R(OMESH(NOM)%NFCC_R(2)) = KKO
    IJKCELL(LOW_IND:HIGH_IND,I,J,K) = (/ NOM, OMESH(NOM)%NFCC_R(2) /)
 ENDIF

RETURN
END SUBROUTINE ASSIGN_TO_CC_R

! ---------------------------- ASSIGN_TO_FC_R ---------------------------------

SUBROUTINE ASSIGN_TO_FC_R

IF (NOM > 0) THEN
   ! Use Automatic reallocation:
   OMESH(NOM)%NFCC_R(1)= OMESH(NOM)%NFCC_R(1) + 1
   SIZE_REC=SIZE(OMESH(NOM)%IIO_FC_R,DIM=1)
   IF(OMESH(NOM)%NFCC_R(1) > SIZE_REC) THEN
       ALLOCATE(IIO_FC_R_AUX(SIZE_REC),JJO_FC_R_AUX(SIZE_REC),KKO_FC_R_AUX(SIZE_REC));
       ALLOCATE(AXS_FC_R_AUX(SIZE_REC))
       IIO_FC_R_AUX(1:SIZE_REC)=OMESH(NOM)%IIO_FC_R(1:SIZE_REC)
       JJO_FC_R_AUX(1:SIZE_REC)=OMESH(NOM)%JJO_FC_R(1:SIZE_REC)
       KKO_FC_R_AUX(1:SIZE_REC)=OMESH(NOM)%KKO_FC_R(1:SIZE_REC)
       AXS_FC_R_AUX(1:SIZE_REC)=OMESH(NOM)%AXS_FC_R(1:SIZE_REC)
       DEALLOCATE(OMESH(NOM)%IIO_FC_R); ALLOCATE(OMESH(NOM)%IIO_FC_R(SIZE_REC+DELTA_FC))
       OMESH(NOM)%IIO_FC_R(1:SIZE_REC)=IIO_FC_R_AUX(1:SIZE_REC)
       DEALLOCATE(OMESH(NOM)%JJO_FC_R); ALLOCATE(OMESH(NOM)%JJO_FC_R(SIZE_REC+DELTA_FC))
       OMESH(NOM)%JJO_FC_R(1:SIZE_REC)=JJO_FC_R_AUX(1:SIZE_REC)
       DEALLOCATE(OMESH(NOM)%KKO_FC_R); ALLOCATE(OMESH(NOM)%KKO_FC_R(SIZE_REC+DELTA_FC))
       OMESH(NOM)%KKO_FC_R(1:SIZE_REC)=KKO_FC_R_AUX(1:SIZE_REC)
       DEALLOCATE(OMESH(NOM)%AXS_FC_R); ALLOCATE(OMESH(NOM)%AXS_FC_R(SIZE_REC+DELTA_FC))
       OMESH(NOM)%AXS_FC_R(1:SIZE_REC)=AXS_FC_R_AUX(1:SIZE_REC)
       DEALLOCATE(IIO_FC_R_AUX,JJO_FC_R_AUX,KKO_FC_R_AUX,AXS_FC_R_AUX)
   ENDIF
   OMESH(NOM)%IIO_FC_R(OMESH(NOM)%NFCC_R(1)) = IIO
   OMESH(NOM)%JJO_FC_R(OMESH(NOM)%NFCC_R(1)) = JJO
   OMESH(NOM)%KKO_FC_R(OMESH(NOM)%NFCC_R(1)) = KKO
   OMESH(NOM)%AXS_FC_R(OMESH(NOM)%NFCC_R(1)) = X1AXIS
   IJKFACE2(LOW_IND:HIGH_IND,I,J,K,X1AXIS) = (/ NOM, OMESH(NOM)%NFCC_R(1) /)
ENDIF

RETURN
END SUBROUTINE ASSIGN_TO_FC_R

! ---------------------------- GET_INTSTENCILS_EP -------------------------------

SUBROUTINE GET_INTSTENCILS_EP(MASK_FLG,VIND,XYZ_PP,INTXN,NVEC,NPE_LIST_START,NPE_LIST_COUNT,&
INT_IJK,INT_COEF)

! This routine provides a set of interpolation points for an external normal point EP,
! located at position XYZE(IAXIS:KAXIS) = XYZ_PP(IAXIS:KAXIS) + INTXN*NVEC(IAXIS:KAXIS):
! The points will be face centered when:
!     VIND = IAXIS => X faces
!            JAXIS => Y faces
!            KAXIS => Z faces
! And cell centered when VIND = 0.
! The number of interpolation points is provided in variable NPE_LIST_COUNT.
! The IJK indexes on mesh of these points is defined in:
! INT_IJK(IAXIS:KAXIS,NPE_LIST_START+1:NPE_LIST_START+NPE_LIST_COUNT)
! INT_COEF(NPE_LIST_START+1:NPE_LIST_START+NPE_LIST_COUNT)

LOGICAL, INTENT(IN) :: MASK_FLG
INTEGER, INTENT(IN) :: VIND,NPE_LIST_START
INTEGER, INTENT(OUT):: NPE_LIST_COUNT
REAL(EB),INTENT(IN) :: XYZ_PP(IAXIS:KAXIS), NVEC(IAXIS:KAXIS), INTXN
INTEGER, INTENT(INOUT), ALLOCATABLE, DIMENSION(:,:) :: INT_IJK
REAL(EB), INTENT(INOUT),ALLOCATABLE, DIMENSION(:)   :: INT_COEF


! Local variables:
REAL(EB) :: XYZE(IAXIS:KAXIS)
LOGICAL  :: IS_FACE_X,IS_FACE_Y,IS_FACE_Z
INTEGER  :: INDX,INDY,INDZ,DIM_NPE,ILO,IHI,JLO,JHI,KLO,KHI,ILO_2,IHI_2,JLO_2,JHI_2,KLO_2,KHI_2
INTEGER  :: II,JJ,KK,DUMAXIS,COUNT
INTEGER, ALLOCATABLE, DIMENSION(:,:,:) :: MASK_IJK
REAL(EB),ALLOCATABLE, DIMENSION(:,:,:) :: RAW_COEF
REAL(EB) :: XYZ_LOHI(LOW_IND:HIGH_IND,IAXIS:KAXIS),X_P(IAXIS:KAXIS),RED_COEF

LOGICAL, PARAMETER :: DO_TRILINEAR = .TRUE.

! Default number of interpolation stencil points:
NPE_LIST_COUNT = 0

! Define external point:
XYZE(IAXIS:KAXIS) = XYZ_PP(IAXIS:KAXIS) + INTXN*NVEC(IAXIS:KAXIS)

! Find closest point on mesh NM to point:
IS_FACE_X=.FALSE.;IS_FACE_Y=.FALSE.;IS_FACE_Z=.FALSE.
IF(VIND==IAXIS) IS_FACE_X=.TRUE.
IF(VIND==JAXIS) IS_FACE_Y=.TRUE.
IF(VIND==KAXIS) IS_FACE_Z=.TRUE.
CALL GET_X_IND(XYZE,IS_FACE_X,INDX)
CALL GET_Y_IND(XYZE,IS_FACE_Y,INDY)
CALL GET_Z_IND(XYZE,IS_FACE_Z,INDZ)

IF(INDX == INDEX_UNDEFINED) RETURN
IF(INDY == INDEX_UNDEFINED) RETURN
IF(INDZ == INDEX_UNDEFINED) RETURN

! Define stencil points:
DIM_NPE = SIZE(INT_IJK, DIM=2)
IF(NPE_LIST_START+MAX_INTERP_POINTS > DIM_NPE) THEN ! Reallocate size of INT_IJK, INT_COEF
   ALLOCATE(INT_IJK_AUX(IAXIS:KAXIS,DIM_NPE),INT_COEF_AUX(1:DIM_NPE))
   INT_IJK_AUX(IAXIS:KAXIS,1:DIM_NPE) = INT_IJK(IAXIS:KAXIS,1:DIM_NPE)
   INT_COEF_AUX(1:DIM_NPE)            = INT_COEF(1:DIM_NPE)
   DEALLOCATE(INT_IJK, INT_COEF)
   ALLOCATE(INT_IJK(IAXIS:KAXIS,NPE_LIST_START+MAX_INTERP_POINTS+DELTA_VERT)); INT_IJK = IBM_UNDEFINED
   ALLOCATE(INT_COEF(1:NPE_LIST_START+MAX_INTERP_POINTS+DELTA_VERT)); INT_COEF = 0._EB
   INT_IJK(IAXIS:KAXIS,1:DIM_NPE) = INT_IJK_AUX(IAXIS:KAXIS,1:DIM_NPE)
   INT_COEF(1:DIM_NPE)            = INT_COEF_AUX(1:DIM_NPE)
   DEALLOCATE(INT_IJK_AUX,INT_COEF_AUX)
ENDIF

! Linear interpolation bounds:
ILO = INDX-1;  IHI = INDX
JLO = INDY-1;  JHI = INDY
KLO = INDZ-1;  KHI = INDZ
! Other interpolation bounds:
IF (STENCIL_INTERPOLATION /= IBM_LINEAR_INTERPOLATION) THEN ! Either QUADRATIC_INTERPOLATION,WLS_INTERPOLATION.
   ILO_2 = ILO_CELL; IHI_2 = IHI_CELL
   JLO_2 = JLO_CELL; JHI_2 = JHI_CELL
   KLO_2 = KLO_CELL; KHI_2 = KHI_CELL
   SELECT CASE(VIND)
   CASE(IAXIS)
      ILO_2 = ILO_FACE; IHI_2 = IHI_FACE
   CASE(JAXIS)
      JLO_2 = JLO_FACE; JHI_2 = JHI_FACE
   CASE(KAXIS)
      KLO_2 = KLO_FACE; KHI_2 = KHI_FACE
   END SELECT
   IF(IHI == IHI_2+NGUARD ) THEN
      ILO = ILO - 1
   ELSEIF(ILO >= ILO_2-NGUARD ) THEN
      IHI = IHI + 1
   ENDIF
   IF(JHI == JHI_2+NGUARD ) THEN
      JLO = JLO - 1
   ELSEIF(JLO >= JLO_2-NGUARD ) THEN
      JHI = JHI + 1
   ENDIF
   IF(KHI == KHI_2+NGUARD ) THEN
      KLO = KLO - 1
   ELSEIF(KLO >= KLO_2-NGUARD ) THEN
      KHI = KHI + 1
   ENDIF

ENDIF

! Allocate stencil Allocatable arrays:
ALLOCATE(MASK_IJK(ILO:IHI,JLO:JHI,KLO:KHI)); MASK_IJK=0;
ALLOCATE(RAW_COEF(ILO:IHI,JLO:JHI,KLO:KHI)); RAW_COEF=0._EB;

! Add collocation points to interpolation stencil:
! Face vars:
IF(VIND > 0) THEN
   IF (MASK_FLG) THEN
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               IF(FCVAR(II,JJ,KK,IBM_FFNF,VIND) /= IBM_GASPHASE) CYCLE ! Cycle if facevar is masked by IBM_FFNF.
               NPE_LIST_COUNT = NPE_LIST_COUNT + 1
               INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/ II, JJ, KK /)
               ! Coeff computation left for the end.
               MASK_IJK(II,JJ,KK) = 1
            ENDDO
         ENDDO
      ENDDO
   ELSE
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               IF(FCVAR(II,JJ,KK,IBM_FGSC,VIND) == IBM_SOLID) CYCLE ! Cycle solid faces.
               NPE_LIST_COUNT = NPE_LIST_COUNT + 1
               INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/ II, JJ, KK /)
               ! Coeff computation left for the end.
               MASK_IJK(II,JJ,KK) = 1
            ENDDO
         ENDDO
      ENDDO
   ENDIF ! MASK_FLG
ELSE ! Centered vars:
   DO KK = KLO,KHI
      DO JJ = JLO,JHI
         DO II = ILO,IHI
            IF(CCVAR(II,JJ,KK,IBM_CGSC) == IBM_SOLID) CYCLE ! Cycle solid cells.
            NPE_LIST_COUNT = NPE_LIST_COUNT + 1
            INT_IJK(IAXIS:KAXIS,NPE_LIST_START+NPE_LIST_COUNT) = (/ II, JJ, KK /)
            ! Coeff computation left for the end.
            MASK_IJK(II,JJ,KK) = 1
         ENDDO
      ENDDO
   ENDDO
ENDIF

! If NPE_LIST_COUNT == 0 return. Will use boundary value only on interpolated face:
IF (NPE_LIST_COUNT == 0) THEN
   DEALLOCATE(MASK_IJK,RAW_COEF)
   RETURN
ENDIF


! At this point we have the interpolation stencil points for EP and VIND mesh.
! Regarding the interpolation type chosen produce the interpolation coefficients in INT_COEFF.
! Define Bounding Box of the Stencil:
IF(VIND==IAXIS) THEN
   XYZ_LOHI(LOW_IND:HIGH_IND,IAXIS) = (/ XFACE(ILO), XFACE(IHI) /)
ELSE
   XYZ_LOHI(LOW_IND:HIGH_IND,IAXIS) = (/ XCELL(ILO), XCELL(IHI) /)
ENDIF
IF(VIND==JAXIS) THEN
   XYZ_LOHI(LOW_IND:HIGH_IND,JAXIS) = (/ YFACE(JLO), YFACE(JHI) /)
ELSE
   XYZ_LOHI(LOW_IND:HIGH_IND,JAXIS) = (/ YCELL(JLO), YCELL(JHI) /)
ENDIF
IF(VIND==KAXIS) THEN
   XYZ_LOHI(LOW_IND:HIGH_IND,KAXIS) = (/ ZFACE(KLO), ZFACE(KHI) /)
ELSE
   XYZ_LOHI(LOW_IND:HIGH_IND,KAXIS) = (/ ZCELL(KLO), ZCELL(KHI) /)
ENDIF

! Masked Trilinear interpolation coefficients:
IF (STENCIL_INTERPOLATION == IBM_LINEAR_INTERPOLATION) THEN
   DO DUMAXIS=IAXIS,KAXIS
      X_P(DUMAXIS) = (XYZE(DUMAXIS)-XYZ_LOHI(LOW_IND,DUMAXIS))/(XYZ_LOHI(HIGH_IND,DUMAXIS)-XYZ_LOHI(LOW_IND,DUMAXIS))
   ENDDO

   ! Case of Trilinear interpolation:
   DO_TRILINEAR_COND : IF (DO_TRILINEAR) THEN
      ! Masked trilinear interpolation:
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               RAW_COEF(II,JJ,KK) = (REAL(II-ILO,EB)*X_P(IAXIS)+REAL(IHI-II,EB)*(1._EB-X_P(IAXIS))) * &
                                    (REAL(JJ-JLO,EB)*X_P(JAXIS)+REAL(JHI-JJ,EB)*(1._EB-X_P(JAXIS))) * &
                                    (REAL(KK-KLO,EB)*X_P(KAXIS)+REAL(KHI-KK,EB)*(1._EB-X_P(KAXIS)))
            ENDDO
         ENDDO
      ENDDO
      ! Rescale remaining coefficients:
      RED_COEF = 0._EB
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               IF (MASK_IJK(II,JJ,KK) == 1) RED_COEF = RED_COEF + RAW_COEF(II,JJ,KK)
            ENDDO
         ENDDO
      ENDDO
      IF (ABS(RED_COEF) < TWO_EPSILON_EB) THEN
         NPE_LIST_COUNT = 0
         DEALLOCATE(MASK_IJK,RAW_COEF)
         RETURN
      ENDIF
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               IF (MASK_IJK(II,JJ,KK) == 1) THEN
                  RAW_COEF(II,JJ,KK) = RAW_COEF(II,JJ,KK)/RED_COEF
               ELSE
                  RAW_COEF(II,JJ,KK) = 0._EB
               ENDIF
            ENDDO
         ENDDO
      ENDDO
      ! Finally add coefficients to INT_COEF:
      COUNT = 0
      DO KK = KLO,KHI
         DO JJ = JLO,JHI
            DO II = ILO,IHI
               IF(MASK_IJK(II,JJ,KK) == 1) THEN
                  COUNT = COUNT + 1
                  INT_COEF(NPE_LIST_START+COUNT) = RAW_COEF(II,JJ,KK)
               ENDIF
            ENDDO
         ENDDO
      ENDDO

   ! Case of Least Squares interpolation with up to 8 stencil points:
   ELSE
      ! To do.

   ENDIF DO_TRILINEAR_COND
   DEALLOCATE(MASK_IJK,RAW_COEF)
   RETURN
ENDIF

! Other interpolation schemes:
! To do.

DEALLOCATE(MASK_IJK,RAW_COEF)
RETURN
END SUBROUTINE GET_INTSTENCILS_EP

SUBROUTINE GET_X_IND(XYZE,IS_FACE,INDX)
REAL(EB),INTENT(IN) :: XYZE(IAXIS:KAXIS)
LOGICAL, INTENT(IN) :: IS_FACE
INTEGER, INTENT(OUT):: INDX
INTEGER :: IEP
INDX = INDEX_UNDEFINED
IF (IS_FACE) THEN ! X face.
   IF(XYZE(IAXIS) >= XFACE(ILO_FACE-NGUARD)) THEN
      DO IEP=ILO_FACE-CCGUARD,IHI_FACE+CCGUARD
         IF (XYZE(IAXIS)+GEOFCT*GEOMEPS < XFACE(IEP)) THEN ! First X index that XYZ(IAXIS) is smaller.
            INDX = IEP; RETURN
         ENDIF
      ENDDO
   ENDIF
ELSE ! X center.
   IF(XYZE(IAXIS) >= XCELL(ILO_CELL-NGUARD)) THEN
      DO IEP=ILO_CELL-CCGUARD,IHI_CELL+CCGUARD
         IF (XYZE(IAXIS)+GEOFCT*GEOMEPS < XCELL(IEP)) THEN ! First X index that XYZ(IAXIS) is smaller.
            INDX = IEP; RETURN
         ENDIF
      ENDDO
   ENDIF
ENDIF
END SUBROUTINE GET_X_IND

SUBROUTINE GET_Y_IND(XYZE,IS_FACE,INDY)
REAL(EB),INTENT(IN) :: XYZE(IAXIS:KAXIS)
LOGICAL, INTENT(IN) :: IS_FACE
INTEGER, INTENT(OUT):: INDY
INTEGER :: IEP
INDY = INDEX_UNDEFINED
IF (IS_FACE) THEN ! Y face.
   IF(XYZE(JAXIS) >= YFACE(JLO_FACE-NGUARD)) THEN
      DO IEP=JLO_FACE-CCGUARD,JHI_FACE+CCGUARD
         IF (XYZE(JAXIS)+GEOFCT*GEOMEPS < YFACE(IEP)) THEN ! First Y index that XYZ(JAXIS) is smaller.
            INDY = IEP; RETURN
         ENDIF
      ENDDO
   ENDIF
ELSE ! Y center.
   IF(XYZE(JAXIS) >= YCELL(JLO_CELL-NGUARD)) THEN
      DO IEP=JLO_CELL-CCGUARD,JHI_CELL+CCGUARD
         IF (XYZE(JAXIS)+GEOFCT*GEOMEPS < YCELL(IEP)) THEN ! First Y index that XYZ(JAXIS) is smaller.
            INDY = IEP; RETURN
         ENDIF
      ENDDO
   ENDIF
ENDIF
END SUBROUTINE GET_Y_IND

SUBROUTINE GET_Z_IND(XYZE,IS_FACE,INDZ)
REAL(EB),INTENT(IN) :: XYZE(IAXIS:KAXIS)
LOGICAL, INTENT(IN) :: IS_FACE
INTEGER, INTENT(OUT):: INDZ
INTEGER :: IEP
INDZ = INDEX_UNDEFINED
IF (IS_FACE) THEN ! Z face.
   IF(XYZE(KAXIS) >= ZFACE(KLO_FACE-NGUARD)) THEN
      DO IEP=KLO_FACE-CCGUARD,KHI_FACE+CCGUARD
         IF (XYZE(KAXIS)+GEOFCT*GEOMEPS < ZFACE(IEP)) THEN ! First Z index that XYZ(KAXIS) is smaller.
            INDZ = IEP; RETURN
         ENDIF
      ENDDO
   ENDIF
ELSE ! Z center.
   IF(XYZE(KAXIS) >= ZCELL(KLO_CELL-NGUARD)) THEN
      DO IEP=KLO_CELL-CCGUARD,KHI_CELL+CCGUARD
         IF (XYZE(KAXIS)+GEOFCT*GEOMEPS < ZCELL(IEP)) THEN ! First Z index that XYZ(KAXIS) is smaller.
            INDZ = IEP; RETURN
         ENDIF
      ENDDO
   ENDIF
ENDIF
END SUBROUTINE GET_Z_IND


END SUBROUTINE GET_CRTCFCC_INT_STENCILS


! -------------------------------- FILL_IJKO_INTERP_STENCILS ----------------------------

SUBROUTINE FILL_IJKO_INTERP_STENCILS

USE MPI_F08

! Local Variables:
INTEGER :: NM,NOM,N,IERR
TYPE (OMESH_TYPE), POINTER :: M2,M3
TYPE (MPI_REQUEST), ALLOCATABLE, DIMENSION(:) :: REQ0
INTEGER :: N_REQ0
REAL(EB) CPUTIME, CPUTIME_START
LOGICAL :: PROCESS_SENDREC

IF (N_MPI_PROCESSES>1) ALLOCATE(REQ0(2*NMESHES**2))

N_REQ0 = 0

IF(GET_CUTCELLS_VERBOSE) THEN
   WRITE(LU_SETCC,'(A)',advance='no') '   > First loop, CC info..'
   CALL CPU_TIME(CPUTIME_START)
ENDIF

! Exchange number of cut-cells information to be exchanged between MESH and OMESHES:
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      PROCESS_SENDREC = .FALSE.
      DO N=1,MESHES(NM)%N_NEIGHBORING_MESHES
         IF (NOM==MESHES(NM)%NEIGHBORING_MESH(N)) PROCESS_SENDREC = .TRUE.
      ENDDO
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NM)/=MY_RANK  .AND. PROCESS_SENDREC) THEN
         M2 => MESHES(NOM)%OMESH(NM)
         N_REQ0 = N_REQ0 + 1
         CALL MPI_IRECV(M2%NFCC_S(1),2,MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ENDIF
   ENDDO
ENDDO

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START,' sec.'
   CALL CPU_TIME(CPUTIME_START)
   WRITE(LU_SETCC,'(A)',advance='no') '   > Second loop, Barrier and isend..'
ENDIF

! DEFINITION NCCC_S:   MESHES(NOM)%OMESH(NM)%NFCC_S   = MESHES(NM)%OMESH(NOM)%NFCC_R

DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (PROCESS(NM)/=MY_RANK) CYCLE
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      IF (EVACUATION_ONLY(NOM)) CYCLE
      PROCESS_SENDREC = .FALSE.
      DO N=1,MESHES(NOM)%N_NEIGHBORING_MESHES
         IF (NM==MESHES(NOM)%NEIGHBORING_MESH(N)) PROCESS_SENDREC = .TRUE.
      ENDDO
      IF (.NOT.PROCESS_SENDREC) CYCLE
      M3 => MESHES(NM)%OMESH(NOM)
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NOM)/=MY_RANK) THEN
         N_REQ0 = N_REQ0 + 1
         CALL MPI_ISEND(M3%NFCC_R(1),2,MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ELSE
         M2 => MESHES(NOM)%OMESH(NM)
         M2%NFCC_S(1:2) = M3%NFCC_R(1:2)
      ENDIF
   ENDDO
ENDDO

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START,' sec.'
   CALL CPU_TIME(CPUTIME_START)
   WRITE(LU_SETCC,'(A)',advance='no') '   > MPI_WAITALL and Alloc..'
ENDIF

IF ( (N_REQ0>0) .AND. (N_MPI_PROCESSES>1) ) CALL MPI_WAITALL(N_REQ0,REQ0(1:N_REQ0),MPI_STATUSES_IGNORE,IERR)

! At this point values of M2%NFCC_S should have been received.

! Definition: MESHES(NOM)%OMESH(NM)%IIO_FC_S(:) = MESHES(NM)%OMESH(NOM)%IIO_FC_R(:)
!             MESHES(NOM)%OMESH(NM)%JJO_FC_S(:) = MESHES(NM)%OMESH(NOM)%JJO_FC_R(:)
!             MESHES(NOM)%OMESH(NM)%KKO_FC_S(:) = MESHES(NM)%OMESH(NOM)%KKO_FC_R(:)
!             MESHES(NOM)%OMESH(NM)%AXS_FC_S(:) = MESHES(NM)%OMESH(NOM)%AXS_FC_R(:)

! Exchange list of face and cutcells data:
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M2 => MESHES(NOM)%OMESH(NM)
      IF (M2%NFCC_S(1)>0) THEN
         ALLOCATE(M2%IIO_FC_S(M2%NFCC_S(1)))
         ALLOCATE(M2%JJO_FC_S(M2%NFCC_S(1)))
         ALLOCATE(M2%KKO_FC_S(M2%NFCC_S(1)))
         ALLOCATE(M2%AXS_FC_S(M2%NFCC_S(1)))
      ENDIF
      IF (M2%NFCC_S(2)>0) THEN
         ALLOCATE(M2%IIO_CC_S(M2%NFCC_S(2)))
         ALLOCATE(M2%JJO_CC_S(M2%NFCC_S(2)))
         ALLOCATE(M2%KKO_CC_S(M2%NFCC_S(2)))
      ENDIF
   ENDDO
ENDDO

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START,' sec.'
   CALL CPU_TIME(CPUTIME_START)
   WRITE(LU_SETCC,'(A)',advance='no') '   > Faces non-blocking send-receives..'
ENDIF

! Faces:
N_REQ0 = 0
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M2 => MESHES(NOM)%OMESH(NM)
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NM)/=MY_RANK .AND. M2%NFCC_S(1)>0) THEN
         CALL MPI_IRECV(M2%IIO_FC_S(1),M2%NFCC_S(1),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+1),IERR)
         CALL MPI_IRECV(M2%JJO_FC_S(1),M2%NFCC_S(1),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+2),IERR)
         CALL MPI_IRECV(M2%KKO_FC_S(1),M2%NFCC_S(1),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+3),IERR)
         CALL MPI_IRECV(M2%AXS_FC_S(1),M2%NFCC_S(1),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+4),IERR)
         N_REQ0 = N_REQ0 + 4
      ENDIF
   ENDDO
ENDDO
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M3 => MESHES(NM)%OMESH(NOM)
      IF (M3%NFCC_R(1)<1) CYCLE
      IF (PROCESS(NOM)/=MY_RANK) THEN
         CALL MPI_ISEND(M3%IIO_FC_R(1),M3%NFCC_R(1),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+1),IERR)
         CALL MPI_ISEND(M3%JJO_FC_R(1),M3%NFCC_R(1),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+2),IERR)
         CALL MPI_ISEND(M3%KKO_FC_R(1),M3%NFCC_R(1),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+3),IERR)
         CALL MPI_ISEND(M3%AXS_FC_R(1),M3%NFCC_R(1),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+4),IERR)
         N_REQ0 = N_REQ0 + 4
      ELSE
         M2 => MESHES(NOM)%OMESH(NM)
         M2%IIO_FC_S(1:M2%NFCC_S(1)) = M3%IIO_FC_R(1:M3%NFCC_R(1))
         M2%JJO_FC_S(1:M2%NFCC_S(1)) = M3%JJO_FC_R(1:M3%NFCC_R(1))
         M2%KKO_FC_S(1:M2%NFCC_S(1)) = M3%KKO_FC_R(1:M3%NFCC_R(1))
         M2%AXS_FC_S(1:M2%NFCC_S(1)) = M3%AXS_FC_R(1:M3%NFCC_R(1))
      ENDIF
   ENDDO
ENDDO

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START,' sec.'
   CALL CPU_TIME(CPUTIME_START)
   WRITE(LU_SETCC,'(A)',advance='no') '   > MPI_WAITALL Faces..'
ENDIF

IF ( (N_REQ0>0) .AND. (N_MPI_PROCESSES>1) ) CALL MPI_WAITALL(N_REQ0,REQ0(1:N_REQ0),MPI_STATUSES_IGNORE,IERR)

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START,' sec.'
   CALL CPU_TIME(CPUTIME_START)
   WRITE(LU_SETCC,'(A)',advance='no') '   > Cells non-blocking send-receives..'
ENDIF

! Cells:
N_REQ0 = 0
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M2 => MESHES(NOM)%OMESH(NM)
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NM)/=MY_RANK .AND. M2%NFCC_S(2)>0) THEN
         CALL MPI_IRECV(M2%IIO_CC_S(1),M2%NFCC_S(2),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+1),IERR)
         CALL MPI_IRECV(M2%JJO_CC_S(1),M2%NFCC_S(2),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+2),IERR)
         CALL MPI_IRECV(M2%KKO_CC_S(1),M2%NFCC_S(2),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+3),IERR)
         N_REQ0 = N_REQ0 + 3
      ENDIF
   ENDDO
ENDDO
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M3 => MESHES(NM)%OMESH(NOM)
      IF (M3%NFCC_R(2)<1) CYCLE
      IF (PROCESS(NOM)/=MY_RANK) THEN
         CALL MPI_ISEND(M3%IIO_CC_R(1),M3%NFCC_R(2),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+1),IERR)
         CALL MPI_ISEND(M3%JJO_CC_R(1),M3%NFCC_R(2),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+2),IERR)
         CALL MPI_ISEND(M3%KKO_CC_R(1),M3%NFCC_R(2),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0+3),IERR)
         N_REQ0 = N_REQ0 + 3
      ELSE
         M2 => MESHES(NOM)%OMESH(NM)
         M2%IIO_CC_S(1:M2%NFCC_S(2)) = M3%IIO_CC_R(1:M3%NFCC_R(2))
         M2%JJO_CC_S(1:M2%NFCC_S(2)) = M3%JJO_CC_R(1:M3%NFCC_R(2))
         M2%KKO_CC_S(1:M2%NFCC_S(2)) = M3%KKO_CC_R(1:M3%NFCC_R(2))
      ENDIF
   ENDDO
ENDDO

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START,' sec.'
   CALL CPU_TIME(CPUTIME_START)
   WRITE(LU_SETCC,'(A)',advance='no') '   > MPI_WAITALL Cells..'
ENDIF

IF ( (N_REQ0>0) .AND. (N_MPI_PROCESSES>1) ) CALL MPI_WAITALL(N_REQ0,REQ0(1:N_REQ0),MPI_STATUSES_IGNORE,IERR)

IF(GET_CUTCELLS_VERBOSE) THEN
   CALL CPU_TIME(CPUTIME)
   WRITE(LU_SETCC,'(A,F8.3,A)') ' done. Time taken : ',CPUTIME-CPUTIME_START,' sec.'
ENDIF

IF(ALLOCATED(REQ0)) DEALLOCATE(REQ0)

RETURN
END SUBROUTINE FILL_IJKO_INTERP_STENCILS


! --------------------------- GET_CLSPT_INBCF -----------------------------------

SUBROUTINE GET_CLSPT_INBCF(NM,XYZ,INBFC,INBFC_LOC,XYZ_IP,DIST,FOUNDPT,INSEG,INSEG2)

INTEGER,  INTENT(IN) :: NM, INBFC, INBFC_LOC
REAL(EB), INTENT(IN) :: XYZ(MAX_DIM)
REAL(EB), INTENT(OUT):: XYZ_IP(MAX_DIM), DIST
LOGICAL,  INTENT(OUT):: FOUNDPT, INSEG
LOGICAL,  OPTIONAL, INTENT(OUT):: INSEG2

! Local Variables:
INTEGER :: BODTRI(1:2),VERT_CUTFACE
INTEGER, ALLOCATABLE, DIMENSION(:) :: CFELEM
INTEGER :: X1AXIS,X2AXIS,X3AXIS
INTEGER :: IBOD,IWSEL,NVFACE,IPT,NVERT
REAL(EB):: NVEC(MAX_DIM),ANVEC(MAX_DIM),P0(MAX_DIM),A,B,C,D,PROJ_COEFF,XYZ_P(MAX_DIM)
REAL(EB):: PTCEN(IAXIS:JAXIS) !,AREAI,V1(IAXIS:JAXIS),V2(IAXIS:JAXIS)
REAL(EB):: SQRDIST, SQRDISTI, X2X3_1(IAXIS:JAXIS), X2X3_2(IAXIS:JAXIS)
REAL(EB):: DP(IAXIS:JAXIS),PCM1(IAXIS:JAXIS),PCM2(IAXIS:JAXIS),X2X3_IP(IAXIS:JAXIS)
REAL(EB):: T,DPDOTDP,SLOC,ATEST
REAL(EB):: P(IAXIS:KAXIS),DPP(IAXIS:KAXIS)
LOGICAL :: IN_POLY

! Initialize:
XYZ_IP(IAXIS:KAXIS) = 0._EB
DIST    = 1._EB / GEOMEPS
FOUNDPT = .FALSE.
INSEG   = .FALSE.
IF(PRESENT(INSEG2)) INSEG2=.FALSE.

VERT_CUTFACE = SIZE(MESHES(NM)%CUT_FACE(INBFC)%CFELEM, DIM=1); ALLOCATE(CFELEM(1:VERT_CUTFACE+1))
CFELEM(1:VERT_CUTFACE)  = MESHES(NM)%CUT_FACE(INBFC)%CFELEM(1:VERT_CUTFACE,INBFC_LOC)
BODTRI(1:2)  = MESHES(NM)%CUT_FACE(INBFC)%BODTRI(1:2,INBFC_LOC)

! normal vector to boundary surface triangle:
IBOD    = BODTRI(1)
IWSEL   = BODTRI(2)
NVEC(IAXIS:KAXIS)    = GEOMETRY(IBOD)%FACES_NORMAL(IAXIS:KAXIS,IWSEL)
NVFACE  = CFELEM(1);   CFELEM(NVFACE+2)=CFELEM(2)

! Plane equation for INBOUNDARY cut-face plane:
! Location of first point in cf polygon is P0:
IPT = 1
P0(IAXIS:KAXIS) = MESHES(NM)%CUT_FACE(INBFC)%XYZVERT(IAXIS:KAXIS,CFELEM(IPT+1))
A = NVEC(IAXIS)
B = NVEC(JAXIS)
C = NVEC(KAXIS)
D = -(A*P0(IAXIS) + B*P0(JAXIS) + C*P0(KAXIS))

! Project xyz point into plane of cf polygon:
PROJ_COEFF = (A*XYZ(IAXIS)+B*XYZ(JAXIS)+C*XYZ(KAXIS)) + D ! /dot(n,n) = 1
XYZ_P(IAXIS:KAXIS) = XYZ(IAXIS:KAXIS) - PROJ_COEFF*NVEC(IAXIS:KAXIS)

! Which Cartesian plane we project to?
ANVEC(IAXIS) = ABS(NVEC(IAXIS)); ANVEC(JAXIS) = ABS(NVEC(JAXIS)); ANVEC(KAXIS) = ABS(NVEC(KAXIS))
IF ( MAX(ANVEC(IAXIS),MAX(ANVEC(JAXIS),ANVEC(KAXIS))) == ANVEC(IAXIS) ) THEN
   X1AXIS = IAXIS; X2AXIS = JAXIS; X3AXIS = KAXIS
ELSEIF ( MAX(ANVEC(IAXIS),MAX(ANVEC(JAXIS),ANVEC(KAXIS))) == ANVEC(JAXIS) ) THEN
   X1AXIS = JAXIS; X2AXIS = KAXIS; X3AXIS = IAXIS
ELSE
   X1AXIS = KAXIS; X2AXIS = IAXIS; X3AXIS = JAXIS
ENDIF

! Now find closest point in projected plane:
! First: Test if point is inside cf area: Compute area of triangles formed
! by projected point xyz_p in x2,x3 plane and cf XYZvert, resp to
! CUT_FACE.area*nvec(x1axis), i.e. cut-face area projected on the Cartesian
! plane orthogonal to x1axis:
PTCEN(IAXIS:JAXIS) = XYZ_P( (/ X2AXIS, X3AXIS /) )
NVERT = SIZE(MESHES(NM)%CUT_FACE(INBFC)%XYZVERT,DIM=2)
ATEST = MESHES(NM)%CUT_FACE(INBFC)%AREA(INBFC_LOC)*ANVEC(X1AXIS) ! Test Area is projected area into X1AXIS.
CALL POINT_IN_POLYGON(PTCEN,VERT_CUTFACE+1,CFELEM,NVERT,X2AXIS,X3AXIS,MESHES(NM)%CUT_FACE(INBFC)%XYZVERT,IN_POLY,ATEST=ATEST)

! Test if inside:
IF (IN_POLY) THEN
   ! Same areas, xyz_p inside INBOUNDARY cut-face:
   XYZ_IP(IAXIS:KAXIS) = XYZ_P(IAXIS:KAXIS)
   DIST   = SQRT( (XYZ(IAXIS)-XYZ_IP(IAXIS))**2._EB + &
                  (XYZ(JAXIS)-XYZ_IP(JAXIS))**2._EB + &
                  (XYZ(KAXIS)-XYZ_IP(KAXIS))**2._EB )
   FOUNDPT= .TRUE.
   ! Now check if point is in segment:
   IF (PRESENT(INSEG2)) THEN
      DO IPT=1,NVFACE
          P(IAXIS:KAXIS)  = MESHES(NM)%CUT_FACE(INBFC)%XYZVERT(IAXIS:KAXIS,CFELEM(IPT+1))
          DPP(IAXIS:KAXIS)= MESHES(NM)%CUT_FACE(INBFC)%XYZVERT(IAXIS:KAXIS,CFELEM(IPT+2))-P(IAXIS:KAXIS)
          IF (NORM2(DPP(IAXIS:KAXIS)) < TWO_EPSILON_EB) CYCLE
          DPP(IAXIS:KAXIS)=DPP(IAXIS:KAXIS)/NORM2(DPP(IAXIS:KAXIS))
          P = XYZ_IP - (P + DOT_PRODUCT(DPP,XYZ_IP-P)*DPP)
          IF (NORM2(P(IAXIS:KAXIS)) < GEOMEPS) THEN
             INSEG = .TRUE.
             INSEG2= .TRUE.
             EXIT
          ENDIF
      ENDDO
   ENDIF
   DEALLOCATE(CFELEM)
   RETURN
ENDIF

! Second, test against segments: Find closest point in segments in x2,x3 plane:
SQRDIST = 1._EB / GEOMEPS
DO IPT=1,NVFACE

    X2X3_1(IAXIS:JAXIS) = MESHES(NM)%CUT_FACE(INBFC)%XYZVERT((/ X2AXIS, X3AXIS /) ,CFELEM(IPT+1))
    X2X3_2(IAXIS:JAXIS) = MESHES(NM)%CUT_FACE(INBFC)%XYZVERT((/ X2AXIS, X3AXIS /) ,CFELEM(IPT+2))

    ! Smallest distance from point PC to segment x2x3_1-x2x3_2:
    DP(IAXIS:JAXIS)     = X2X3_2(IAXIS:JAXIS) - X2X3_1(IAXIS:JAXIS)
    PCM1(IAXIS:JAXIS)   =  PTCEN(IAXIS:JAXIS) - X2X3_1(IAXIS:JAXIS)
    T      = DP(IAXIS)*PCM1(IAXIS) + DP(JAXIS)*PCM1(JAXIS)
    DPDOTDP= DP(IAXIS)**2._EB + DP(JAXIS)**2._EB

    IF ( T < GEOMEPS ) THEN
        SQRDISTI = PCM1(IAXIS)**2._EB + PCM1(JAXIS)**2._EB ! x2x3_1 is closest pt.
        T = 0._EB
    ELSEIF ( T >= DPDOTDP ) THEN
        PCM2(IAXIS:JAXIS) = PTCEN(IAXIS:JAXIS) - X2X3_2(IAXIS:JAXIS)
        SQRDISTI = PCM2(IAXIS)**2._EB + PCM2(JAXIS)**2._EB ! x2x3_2 is closest pt.
        T = DPDOTDP
    ELSE
        SQRDISTI =(PCM1(IAXIS)**2._EB + PCM1(JAXIS)**2._EB) - T**2._EB/DPDOTDP
    ENDIF

    ! Test:
    IF ( SQRDISTI < SQRDIST ) THEN
        SQRDIST = SQRDISTI
        SLOC    = T/(DPDOTDP+TWO_EPSILON_EB)
        X2X3_IP(IAXIS:JAXIS) = X2X3_1(IAXIS:JAXIS) + SLOC * DP(IAXIS:JAXIS) ! intersection point in segment,
                                                                            ! plane x2,x3
        FOUNDPT= .TRUE.
        INSEG  = .TRUE.
    ENDIF
ENDDO

! Now pass x2x3 intersection point to 3D:
IF (FOUNDPT) THEN
    SELECT CASE(X1AXIS)
        CASE(IAXIS)
            XYZ_IP(JAXIS) = X2X3_IP(IAXIS)
            XYZ_IP(KAXIS) = X2X3_IP(JAXIS)
            XYZ_IP(IAXIS) = (-B*XYZ_IP(JAXIS) -C*XYZ_IP(KAXIS) - D)/A
        CASE(JAXIS)
            XYZ_IP(KAXIS) = X2X3_IP(IAXIS)
            XYZ_IP(IAXIS) = X2X3_IP(JAXIS)
            XYZ_IP(JAXIS) = (-A*XYZ_IP(IAXIS) -C*XYZ_IP(KAXIS) - D)/B
        CASE(KAXIS)
            XYZ_IP(IAXIS) = X2X3_IP(IAXIS)
            XYZ_IP(JAXIS) = X2X3_IP(JAXIS)
            XYZ_IP(KAXIS) = (-A*XYZ_IP(IAXIS) -B*XYZ_IP(JAXIS) - D)/C
    END SELECT
    DIST   = SQRT( (XYZ(IAXIS)-XYZ_IP(IAXIS))**2._EB + &
                   (XYZ(JAXIS)-XYZ_IP(JAXIS))**2._EB + &
                   (XYZ(KAXIS)-XYZ_IP(KAXIS))**2._EB )
ENDIF

DEALLOCATE(CFELEM)

RETURN
END SUBROUTINE GET_CLSPT_INBCF


! -------------------------- GET_CLOSEPT_CCVT -----------------------------------

SUBROUTINE GET_CLOSEPT_CCVT(NM,XYZ,ICC,XYZ_IP,DIST,FOUNDPT,IFCPT,IFCPT_LOC)

INTEGER,  INTENT(IN) :: NM, ICC
REAL(EB), INTENT(IN) :: XYZ(MAX_DIM)
REAL(EB), INTENT(OUT):: XYZ_IP(MAX_DIM), DIST
INTEGER,  INTENT(OUT):: IFCPT, IFCPT_LOC
LOGICAL,  INTENT(OUT):: FOUNDPT

! Local Variables:
INTEGER :: I,J,K,IJK(MAX_DIM),IJK_CELL(MAX_DIM),LOWHIGH,IND_ADD
INTEGER :: X1AXIS,X2AXIS,X3AXIS,XIAXIS,XJAXIS,XKAXIS,CEI,ICF,IX2,IX3
LOGICAL :: INLIST, ISCORN
INTEGER :: INDXI(MAX_DIM),IPT,IVERT,ICORN,INDI,INDJ,INDK
REAL(EB), POINTER, DIMENSION(:) :: X2FC,X3FC!,X1FC,X1CL,X2CL,X3CL,DX1FC,DX2FC,DX3FC,DX1CL,DX2CL,DX3CL
REAL(EB):: DV(MAX_DIM),XY1(1:4,IAXIS:JAXIS)
INTEGER :: JJ,KK,INDXI1(IAXIS:JAXIS),INDXI2(IAXIS:JAXIS),INDXI3(IAXIS:JAXIS),INDXI4(IAXIS:JAXIS)
LOGICAL :: CEIFLG

! Initialize:
XYZ_IP(IAXIS:KAXIS) = 0._EB
DIST    = 1._EB / GEOMEPS
FOUNDPT = .FALSE.
IFCPT   = 0; IFCPT_LOC = 0

! Here we need to look at Cartesian faces that are boundary of
! CUT_CELL(icc) (which has only regular or Gasphase cut-faces of regular
! size and find if a corner point (or sigular point) is type SOLID. The
! point found provides xyz_ip:
IJK_CELL(IAXIS:KAXIS) = MESHES(NM)%CUT_CELL(ICC)%IJK(IAXIS:KAXIS)

! Loop on different planes:
LOWHIGH_IND_LOOP : DO LOWHIGH=LOW_IND,HIGH_IND

   IND_ADD = LOWHIGH - LOW_IND  ! Index to add for face LOW-HIGH resp to cell.

   X1AXIS_LOOP : DO X1AXIS=IAXIS,KAXIS

      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         I = IJK_CELL(IAXIS)-1+IND_ADD
         J = IJK_CELL(JAXIS)
         K = IJK_CELL(KAXIS)
         X2AXIS = JAXIS; X3AXIS = KAXIS
         ! location in I,J,K of x1,x2,x3 axes:
         XIAXIS = IAXIS; XJAXIS = JAXIS; XKAXIS = KAXIS
         ! Centroid coordinates in x1,x2,x3 axes:
         ! X2CL => YCELL; DX2CL => DYCELL
         ! X3CL => ZCELL; DX3CL => DZCELL
         ! X1FC => XFACE
         X2FC => YFACE
         X3FC => ZFACE

      CASE(JAXIS)
         I = IJK_CELL(IAXIS)
         J = IJK_CELL(JAXIS)-1+IND_ADD
         K = IJK_CELL(KAXIS)
         X2AXIS = KAXIS; X3AXIS = IAXIS
         ! location in I,J,K of x1,x2,x3 axes:
         XIAXIS = KAXIS; XJAXIS = IAXIS; XKAXIS = JAXIS
         ! Centroid coordinates in x1,x2,x3 axes:
         ! X2CL => ZCELL; DX2CL => DZCELL
         ! X3CL => XCELL; DX3CL => DXCELL
         ! X1FC => YFACE;
         X2FC => ZFACE;
         X3FC => XFACE;
      CASE(KAXIS)

         I = IJK_CELL(IAXIS)
         J = IJK_CELL(JAXIS)
         K = IJK_CELL(KAXIS)-1+IND_ADD
         X2AXIS = IAXIS; X3AXIS = JAXIS
         ! location in I,J,K of x1,x2,x3 axes:
         XIAXIS = JAXIS; XJAXIS = KAXIS; XKAXIS = IAXIS
         ! Face coordinates in x1,x2,x3 axes:
         ! X2CL => XCELL; DX2CL => DXCELL
         ! X3CL => YCELL; DX3CL => DYCELL
         ! X1FC => ZFACE
         X2FC => XFACE
         X3FC => YFACE

      END SELECT

      ! Drop if face is regular GASPHASE or SOLID:
      IF ( MESHES(NM)%FCVAR(I,J,K,IBM_FGSC,X1AXIS) /= IBM_CUTCFE ) CYCLE

      ! Face IJK:
      IJK(IAXIS:KAXIS) = (/ I, J, K /)

      ! Cartesian Face centroid location x2-x3 plane:
      CEI = MESHES(NM)%FCVAR(I,J,K,IBM_IDCE,X1AXIS)
      ICF = MESHES(NM)%FCVAR(I,J,K,IBM_IDCF,X1AXIS)

      ! We might have single point CEIs:
      CEIFLG = .FALSE.
      IF (CEI <= 0) THEN
         CEIFLG = .TRUE.
      ELSEIF ( MESHES(NM)%CUT_EDGE(CEI)%NVERT == 1 ) THEN
         CEIFLG = .TRUE.
      ENDIF

      IF (CEIFLG) THEN ! Cut face is one regular face, with one SOLID vertex.

         ! Figure out which vertex is SOLID and location:
         INLIST = .FALSE.
         DO IX3=0,1
            DO IX2=0,1
               ! Vertex axes:
               INDXI(IAXIS:KAXIS) = (/ IJK(X1AXIS), IJK(X2AXIS)-1+IX2, IJK(X3AXIS)-1+IX3 /) ! x1,x2,x3
               INDI = INDXI(XIAXIS)
               INDJ = INDXI(XJAXIS)
               INDK = INDXI(XKAXIS)
               IF ( MESHES(NM)%VERTVAR(INDI,INDJ,INDK,IBM_VGSC) == IBM_SOLID ) THEN
                  INLIST = .TRUE.
                  EXIT
               ENDIF
            ENDDO
            IF (INLIST) THEN
               XYZ_IP(IAXIS:KAXIS)  = (/ XFACE(INDI), YFACE(INDJ), ZFACE(INDK) /)
               DIST   = SQRT( (XYZ(IAXIS)-XYZ_IP(IAXIS))**2._EB + &
                              (XYZ(JAXIS)-XYZ_IP(JAXIS))**2._EB + &
                              (XYZ(KAXIS)-XYZ_IP(KAXIS))**2._EB )
               IFCPT  = ICF
               ! Find local point:
               DO IPT=1,MESHES(NM)%CUT_FACE(ICF)%NVERT
                  DV = MESHES(NM)%CUT_FACE(ICF)%XYZVERT(IAXIS:KAXIS,IPT) - XYZ_IP(IAXIS:KAXIS)
                  IF( (ABS(DV(IAXIS))+ABS(DV(JAXIS))+ABS(DV(KAXIS))) < GEOMEPS ) THEN
                     IFCPT_LOC = IPT
                     EXIT
                  ENDIF
               ENDDO
               FOUNDPT = .TRUE.
               RETURN
            ENDIF
         ENDDO

         ! Check if there are more than 4 vertices, get vertex that is not in corners:
         IF ( MESHES(NM)%CUT_FACE(ICF)%NVERT > 4 ) THEN

            JJ = IJK(X2AXIS); KK = IJK(X3AXIS)
            ! Vertex at index jj-1,kk-1:
            INDXI1(IAXIS:JAXIS) = (/ JJ-1  , KK-1   /) ! Local x2,x3
            ! Vertex at index jj,kk-1:
            INDXI2(IAXIS:JAXIS) = (/ JJ    , KK-1   /) ! Local x2,x3
            ! Vertex at index jj,kk:
            INDXI3(IAXIS:JAXIS) = (/ JJ    , KK     /) ! Local x2,x3
            ! Vertex at index jj-1,kk:
            INDXI4(IAXIS:JAXIS) = (/ JJ-1  , KK     /) ! Local x2,x3

            XY1(1:4,IAXIS) = (/ X2FC(INDXI1(IAXIS)), X2FC(INDXI2(IAXIS)), &
                                X2FC(INDXI3(IAXIS)), X2FC(INDXI4(IAXIS)) /)
            XY1(1:4,JAXIS) = (/ X3FC(INDXI1(JAXIS)), X3FC(INDXI2(JAXIS)), &
                                X3FC(INDXI3(JAXIS)), X3FC(INDXI4(JAXIS)) /)

            ! Find vertex:
            DO IVERT=1,MESHES(NM)%CUT_FACE(ICF)%NVERT
               ISCORN = .FALSE.
               DO ICORN=1,4
                  IF( SQRT( (XY1(ICORN,IAXIS)-MESHES(NM)%CUT_FACE(ICF)%XYZVERT(X2AXIS,IVERT))**2._EB + &
                            (XY1(ICORN,JAXIS)-MESHES(NM)%CUT_FACE(ICF)%XYZVERT(X3AXIS,IVERT))**2._EB ) &
                            < GEOMEPS) THEN
                     ISCORN = .TRUE.
                     EXIT
                  ENDIF
               ENDDO
               IF (.NOT.ISCORN) THEN
                  XYZ_IP(IAXIS:KAXIS) = MESHES(NM)%CUT_FACE(ICF)%XYZVERT(IAXIS:KAXIS,IVERT)
                  INLIST = .TRUE.
                  EXIT
               ENDIF
            ENDDO
            IF (INLIST) THEN
               DIST   = SQRT( (XYZ(IAXIS)-XYZ_IP(IAXIS))**2._EB + &
                              (XYZ(JAXIS)-XYZ_IP(JAXIS))**2._EB + &
                              (XYZ(KAXIS)-XYZ_IP(KAXIS))**2._EB )
               IFCPT     = ICF
               IFCPT_LOC = IVERT
               FOUNDPT   = .TRUE.
               RETURN
            ENDIF

         ENDIF

      ENDIF ! CEI <= 0

      !NULLIFY(X2CL,X3CL,DX2CL,DX3CL,X1FC,X2FC,X3FC)
      NULLIFY(X2FC,X3FC)

   ENDDO X1AXIS_LOOP

ENDDO LOWHIGH_IND_LOOP


RETURN
END SUBROUTINE GET_CLOSEPT_CCVT


! ----------------------- SET_CCIBM_MATVEC_DATA ---------------------------------

SUBROUTINE SET_CCIBM_MATVEC_DATA

USE MPI_F08

! Local variables:
INTEGER :: NM, I, IPROC, IERR

! Explicit CC time integration: Set threshold volume of linked cells to 0.95 of Cartesian cell vol.
CCVOL_LINK=0.95_EB

! 1. Define unknown numbers for Scalars:
CALL GET_MATRIX_INDEXES_Z


! 2. For each IBM_GASPHASE (cut or regular) face, find global numeration of the volumes
! that share it, store a list of areas and centroids for diffussion operator in FV form.
! 3. Get IBM_GASPHASE regular faces data, for scalars Z:
CALL GET_GASPHASE_REGFACES_DATA

! 4. Get IBM_GASPHASE cut-faces data:
CALL GET_GASPHASE_CUTFACES_DATA ! Here there is no need to populate CELL_LIST on CUT_FACE,
                                ! list of low/high cut-cell volumes that share the cut-face, as
                                ! this has been done before calling SET_CCIBM_MATVEC_DATA, when calling
                                ! GET_CRTCFCC_INT_STENCILS.

! 6. Exchange information at block boundaries for IBM_RCFACE_Z, CUT_FACE
! fields on each mesh:
CALL GET_BOUNDFACE_GEOM_INFO

! 7. Get nonzeros graph of the scalar diffusion/advection matrix, defined as:
!    - NNZ_D_MAT_Z(1:NUNKZ_LOCAL) Number of nonzeros on per matrix row.
!    - JD_MAT_Z(1:NNZ_ROW_Z,1:NUNKZ_LOCAL) Column location of nonzeros, global numeration.
NUNKZ_LOCAL = sum(NUNKZ_LOC(1:NMESHES)) ! Filled in GET_MATRIX_INDEXES, only nonzeros are for meshes
                                        ! that belong to this process.
NUNKZ_TOTAL = sum(NUNKZ_TOT(1:NMESHES))

IF (GET_CUTCELLS_VERBOSE) THEN
   IF (MY_RANK==0) THEN
      WRITE(LU_ERR,*) ' '
      WRITE(LU_ERR,'(A)') ' Cut-cell region scalar transport advanced explicitly.'
      WRITE(LU_ERR,'(A)') ' List of Scalar unknown numbers per proc:'
   ENDIF
   DO IPROC=0,N_MPI_PROCESSES-1
      CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
      IF(MY_RANK==IPROC) WRITE(LU_ERR,'(A,I8,A,I8)') ' MY_RANK=',MY_RANK,', NUNKZ_LOCAL=',NUNKZ_LOCAL
   ENDDO
ENDIF

! Allocate NNZ_D_MAT_Z, JD_MAT_Z:
ALLOCATE( NNZ_D_MAT_Z(1:NUNKZ_LOCAL) )
ALLOCATE( JD_MAT_Z(1:NNZ_ROW_Z,1:NUNKZ_LOCAL) ) ! Contains on first index nonzeros per local row.
NNZ_D_MAT_Z(:) = 0
JD_MAT_Z(:,:)  = HUGE(I)

! Find NM_START: first mesh that belongs to the processor.
NM_START = IBM_UNDEFINED
DO NM=1,NMESHES
   IF (PROCESS(NM)/=MY_RANK) CYCLE
   NM_START = NM
   EXIT
ENDDO

! 8. Build Mass (volumes) matrix for scalars:
CALL GET_MMATRIX_SCALAR_3D

! Allocate rhs and solution arrays for species:
ALLOCATE( F_Z(1:NUNKZ_LOCAL) , F_Z0(1:NUNKZ_LOCAL,1:N_TOTAL_SCALARS) , RZ_Z(1:NUNKZ_LOCAL) , RZ_ZS(1:NUNKZ_LOCAL) )
ALLOCATE( RZ_Z0(1:NUNKZ_LOCAL,1:N_TOTAL_SCALARS) )

RETURN
END SUBROUTINE SET_CCIBM_MATVEC_DATA

! ---------------------- GET_BOUNDFACE_GEOM_INFO --------------------------------
SUBROUTINE GET_BOUNDFACE_GEOM_INFO

! Work deferred.

RETURN
END SUBROUTINE GET_BOUNDFACE_GEOM_INFO

! --------------------- GET_BOUNDFACE_GEOM_INFO_H --------------------------------
SUBROUTINE GET_BOUNDFACE_GEOM_INFO_H

! Work deferred.

RETURN
END SUBROUTINE GET_BOUNDFACE_GEOM_INFO_H

! ----------------------- FILL_UNKZ_GUARDCELLS ---------------------------------
SUBROUTINE FILL_UNKZ_GUARDCELLS

USE MPI_F08

! Local Variables:
INTEGER :: NM,NOM,IERR
TYPE (MESH_TYPE), POINTER :: M
TYPE (OMESH_TYPE), POINTER :: M2,M3
TYPE (MPI_REQUEST), ALLOCATABLE, DIMENSION(:) :: REQ0
INTEGER :: N_REQ0, NICC_R, ICC, ICC1, NCELL, JCC
INTEGER, ALLOCATABLE, DIMENSION(:) :: NCC_SV
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC
INTEGER :: ISTR,IEND,JSTR,JEND,KSTR,KEND,IIO,JJO,KKO,IOR,IW,N_INT
LOGICAL :: ALL_FLG

! First allocate buffers to receive UNKZ information:
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      IF (EVACUATION_ONLY(NOM)) CYCLE
      IF (MESHES(NM)%OMESH(NOM)%NIC_R>0) THEN
         M3 => MESHES(NM)%OMESH(NOM)
         ALLOCATE(M3%UNKZ_CT_R(M3%NIC_R))
      ENDIF
      IF (MESHES(NM)%OMESH(NOM)%NICC_R(1)>0) THEN
         M3 => MESHES(NM)%OMESH(NOM)
         ALLOCATE(M3%ICC_UNKZ_CC_R(M3%NICC_R(1)))
         ALLOCATE(M3%UNKZ_CC_R(M3%NICC_R(2)))

         ! Dump cut-cell indexes on sending mesh NOM, whose info will be received:
         NICC_R = 0
         CALL POINT_TO_MESH(NM)
         ! Loop over cut-cells:
         EXTERNAL_WALL_LOOP_1 : DO IW=1,N_EXTERNAL_WALL_CELLS
            WC=>WALL(IW)
            EWC=>EXTERNAL_WALL(IW)
            IF (.NOT.(WC%BOUNDARY_TYPE == INTERPOLATED_BOUNDARY .OR. &
                      WC%BOUNDARY_TYPE == MIRROR_BOUNDARY) ) CYCLE EXTERNAL_WALL_LOOP_1
            IF ( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY ) THEN
               IF (EWC%NOM/=NOM) CYCLE EXTERNAL_WALL_LOOP_1
               IF (CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_CGSC) /= IBM_CUTCFE) CYCLE EXTERNAL_WALL_LOOP_1
               DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
                  DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
                     DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
                       ICC   = MESHES(NOM)%CCVAR(IIO,JJO,KKO,IBM_IDCC)
                       IF (ICC > 0) THEN
                          NICC_R = NICC_R + 1
                          M3%ICC_UNKZ_CC_R(NICC_R) = ICC ! Note : This ICC index refers to NOM mesh.
                       ENDIF
                     ENDDO
                  ENDDO
               ENDDO
            ELSEIF ( WC%BOUNDARY_TYPE==MIRROR_BOUNDARY ) THEN
               IF (NM/=NOM) CYCLE EXTERNAL_WALL_LOOP_1
               IF (CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_CGSC) /= IBM_CUTCFE) CYCLE EXTERNAL_WALL_LOOP_1
               IIO = WC%ONE_D%IIG
               JJO = WC%ONE_D%JJG
               KKO = WC%ONE_D%KKG
               IOR = WC%ONE_D%IOR
               ! CYCLE if OBJECT face is in the Mirror Boundary, normal out into ghost-cell:
               SELECT CASE(IOR)
               CASE( IAXIS)
                  IF(FCVAR(IIO-1,JJO  ,KKO  ,IBM_FGSC,IAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_1
               CASE(-IAXIS)
                  IF(FCVAR(IIO  ,JJO  ,KKO  ,IBM_FGSC,IAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_1
               CASE( JAXIS)
                  IF(FCVAR(IIO  ,JJO-1,KKO  ,IBM_FGSC,JAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_1
               CASE(-JAXIS)
                  IF(FCVAR(IIO  ,JJO  ,KKO  ,IBM_FGSC,JAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_1
               CASE( KAXIS)
                  IF(FCVAR(IIO  ,JJO  ,KKO-1,IBM_FGSC,KAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_1
               CASE(-KAXIS)
                  IF(FCVAR(IIO  ,JJO  ,KKO  ,IBM_FGSC,KAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_1
               END SELECT
               ICC = MESHES(NOM)%CCVAR(IIO,JJO,KKO,IBM_IDCC)
               NICC_R = NICC_R + 1
               M3%ICC_UNKZ_CC_R(NICC_R) = ICC ! Note : This ICC index refers to NOM==NM mesh.
            ENDIF
         ENDDO EXTERNAL_WALL_LOOP_1
      ENDIF
   ENDDO
ENDDO

CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)

IF (N_MPI_PROCESSES>1) ALLOCATE(REQ0(2*NMESHES**2))

N_REQ0 = 0

! Exchange number of cut-cells information to be exchanged between MESH and OMESHES:
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NM)/=MY_RANK .AND. MESHES(NOM)%CONNECTED_MESH(NM)) THEN
         M2 => MESHES(NOM)%OMESH(NM)
         N_REQ0 = N_REQ0 + 1
         CALL MPI_IRECV(M2%NICC_S(1),2,MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ENDIF
   ENDDO
ENDDO

! DEFINITION NCC_S:   MESHES(NOM)%OMESH(NM)%NCC_S   = MESHES(NM)%OMESH(NOM)%NCC_R

DO NM=1,NMESHES
   CALL MPI_BARRIER(MPI_COMM_WORLD,IERR)  ! This call orders the sending mesh by mesh.
   IF (PROCESS(NM)/=MY_RANK) CYCLE
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      IF (EVACUATION_ONLY(NOM)) CYCLE
      IF (.NOT.(TWO_D .AND. NMESHES==1) .AND. .NOT.MESHES(NM)%CONNECTED_MESH(NOM)) CYCLE
      M3 => MESHES(NM)%OMESH(NOM)
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NOM)/=MY_RANK .AND. MESHES(NM)%CONNECTED_MESH(NOM)) THEN
         N_REQ0 = N_REQ0 + 1
         CALL MPI_ISEND(M3%NICC_R(1),2,MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ELSE
         M2 => MESHES(NOM)%OMESH(NM)
         M2%NICC_S(1:2) = M3%NICC_R(1:2)
      ENDIF
   ENDDO
ENDDO

IF ( (N_REQ0>0) .AND. (N_MPI_PROCESSES>1) ) THEN
   CALL MPI_WAITALL(N_REQ0,REQ0(1:N_REQ0),MPI_STATUSES_IGNORE,IERR)
ENDIF

! At this point values of M2%NICC_S should have been received.

! Definition: MESHES(NOM)%OMESH(NM)%UNKZ_CT_S(:) = MESHES(NM)%OMESH(NOM)%UNKZ_CT_R(:)
!             MESHES(NOM)%OMESH(NM)%UNKZ_CC_S(:) = MESHES(NM)%OMESH(NOM)%UNKZ_CC_R(:)

! Now allocate buffers to send UNKZ information:
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      IF (MESHES(NOM)%OMESH(NM)%NIC_S>0) THEN
         M2 => MESHES(NOM)%OMESH(NM)
         ALLOCATE(M2%UNKZ_CT_S(M2%NIC_S))
      ENDIF

      IF (MESHES(NOM)%OMESH(NM)%NICC_S(1)>0) THEN
         M2 => MESHES(NOM)%OMESH(NM)
         ALLOCATE(M2%ICC_UNKZ_CC_S(M2%NICC_S(1)))
         ALLOCATE(M2%UNKZ_CC_S(M2%NICC_S(2)))
      ENDIF
   ENDDO
ENDDO

! Exchange list of cutcells in ICC_UNKZ_CC_S/R:
N_REQ0 = 0
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M2 => MESHES(NOM)%OMESH(NM)
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NM)/=MY_RANK .AND. M2%NICC_S(1)>0) THEN
         N_REQ0 = N_REQ0 + 1
         CALL MPI_IRECV(M2%ICC_UNKZ_CC_S(1),M2%NICC_S(1),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ENDIF
   ENDDO
ENDDO
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M3 => MESHES(NM)%OMESH(NOM)
      IF (M3%NICC_R(1)<1) CYCLE
      IF (PROCESS(NOM)/=MY_RANK) THEN
         N_REQ0 = N_REQ0 + 1
         CALL MPI_ISEND(M3%ICC_UNKZ_CC_R(1),M3%NICC_R(1),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ELSE
         M2 => MESHES(NOM)%OMESH(NM)
         M2%ICC_UNKZ_CC_S(1:M2%NICC_S(1)) = M3%ICC_UNKZ_CC_R(1:M3%NICC_R(1))
      ENDIF
   ENDDO
ENDDO

IF ( (N_REQ0>0) .AND. (N_MPI_PROCESSES>1) ) CALL MPI_WAITALL(N_REQ0,REQ0(1:N_REQ0),MPI_STATUSES_IGNORE,IERR)

! Senders populate UNKZ_CC_S with computed UNKZ values:
ALLOCATE(NCC_SV(1:NMESHES));
DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M2 => MESHES(NOM)%OMESH(NM)
      IF (M2%NICC_S(1)<1) CYCLE
      M => MESHES(NOM)
      NCC_SV(NOM) = 0
      DO ICC1=1,M2%NICC_S(1)
         ICC = M2%ICC_UNKZ_CC_S(ICC1)
         NCELL=M%CUT_CELL(ICC)%NCELL
         DO JCC=1,NCELL
            NCC_SV(NOM) = NCC_SV(NOM) + 1
            M2%UNKZ_CC_S(NCC_SV(NOM)) = M%CUT_CELL(ICC)%UNKZ(JCC)
            IF ( M%CUT_CELL(ICC)%UNKZ(JCC) == IBM_UNDEFINED) &
            WRITE(LU_ERR,*) 'NOM MESH UNKZ UNDEFINED',NOM,ICC,JCC,M%CUT_CELL(ICC)%IJK(1:3),M%CUT_CELL(ICC)%UNKZ(JCC)
         ENDDO
      ENDDO
   ENDDO
ENDDO
DEALLOCATE(NCC_SV)

! Finally exchange UNKZ values:
N_REQ0 = 0
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=1,NMESHES
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M3 => MESHES(NM)%OMESH(NOM)
      IF (M3%NICC_R(1)<1) CYCLE
      IF (PROCESS(NOM)/=MY_RANK) THEN
         N_REQ0 = N_REQ0 + 1
         CALL MPI_IRECV(M3%UNKZ_CC_R(1),M3%NICC_R(2),MPI_INTEGER,PROCESS(NOM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ELSE
         M2 => MESHES(NOM)%OMESH(NM)
         M3%UNKZ_CC_R(1:M3%NICC_R(2)) = M2%UNKZ_CC_S(1:M2%NICC_S(2))
      ENDIF
   ENDDO
ENDDO

DO NM=1,NMESHES
   IF (EVACUATION_ONLY(NM)) CYCLE
   DO NOM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      IF (EVACUATION_ONLY(NOM)) CYCLE
      M2 => MESHES(NOM)%OMESH(NM)
      IF (N_MPI_PROCESSES>1 .AND. NM/=NOM .AND. PROCESS(NM)/=MY_RANK .AND. M2%NICC_S(1)>0) THEN
         N_REQ0 = N_REQ0 + 1
         CALL MPI_ISEND(M2%UNKZ_CC_S(1),M2%NICC_S(2),MPI_INTEGER,PROCESS(NM),NM,MPI_COMM_WORLD,REQ0(N_REQ0),IERR)
      ENDIF
   ENDDO
ENDDO

IF ( (N_REQ0>0) .AND. (N_MPI_PROCESSES>1) ) CALL MPI_WAITALL(N_REQ0,REQ0(1:N_REQ0),MPI_STATUSES_IGNORE,IERR)

! Copy to guard-cell cut-cells:
ALLOCATE(NCC_SV(1:NMESHES));
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   M => MESHES(NM)
   NCC_SV(:)=0
   CALL POINT_TO_MESH(NM)
   ! Loop over cut-cells:
   EXTERNAL_WALL_LOOP_2 : DO IW=1,N_EXTERNAL_WALL_CELLS
      WC=>WALL(IW)
      EWC=>EXTERNAL_WALL(IW)
      IF (.NOT.(WC%BOUNDARY_TYPE == INTERPOLATED_BOUNDARY .OR. &
                WC%BOUNDARY_TYPE == MIRROR_BOUNDARY) ) CYCLE EXTERNAL_WALL_LOOP_2
      IF ( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY ) THEN
         IF (CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_CGSC) /= IBM_CUTCFE) CYCLE EXTERNAL_WALL_LOOP_2
         NOM = EWC%NOM
         DO KKO=EWC%KKO_MIN,EWC%KKO_MAX
            DO JJO=EWC%JJO_MIN,EWC%JJO_MAX
               DO IIO=EWC%IIO_MIN,EWC%IIO_MAX
                 ICC   = MESHES(NOM)%CCVAR(IIO,JJO,KKO,IBM_IDCC)
                 IF (ICC > 0) THEN
                    DO JCC=1,MESHES(NOM)%CUT_CELL(ICC)%NCELL
                       NCC_SV(NOM)=NCC_SV(NOM)+1
                       MESHES(NOM)%CUT_CELL(ICC)%UNKZ(JCC) = M%OMESH(NOM)%UNKZ_CC_R(NCC_SV(NOM))
                    ENDDO
                 ENDIF
               ENDDO
            ENDDO
         ENDDO
      ELSEIF ( WC%BOUNDARY_TYPE==MIRROR_BOUNDARY ) THEN
         IIO = WC%ONE_D%IIG
         JJO = WC%ONE_D%JJG
         KKO = WC%ONE_D%KKG
         NOM = NM
         IF (CCVAR(WC%ONE_D%II,WC%ONE_D%JJ,WC%ONE_D%KK,IBM_CGSC) /= IBM_CUTCFE) CYCLE EXTERNAL_WALL_LOOP_2
         IOR = WC%ONE_D%IOR
         ! CYCLE if OBJECT face is in the Mirror Boundary, normal out into ghost-cell:
         SELECT CASE(IOR)
         CASE( IAXIS)
            IF(FCVAR(IIO-1,JJO  ,KKO  ,IBM_FGSC,IAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_2
         CASE(-IAXIS)
            IF(FCVAR(IIO  ,JJO  ,KKO  ,IBM_FGSC,IAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_2
         CASE( JAXIS)
            IF(FCVAR(IIO  ,JJO-1,KKO  ,IBM_FGSC,JAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_2
         CASE(-JAXIS)
            IF(FCVAR(IIO  ,JJO  ,KKO  ,IBM_FGSC,JAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_2
         CASE( KAXIS)
            IF(FCVAR(IIO  ,JJO  ,KKO-1,IBM_FGSC,KAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_2
         CASE(-KAXIS)
            IF(FCVAR(IIO  ,JJO  ,KKO  ,IBM_FGSC,KAXIS) == IBM_SOLID) CYCLE EXTERNAL_WALL_LOOP_2
         END SELECT
         ICC = MESHES(NOM)%CCVAR(IIO,JJO,KKO,IBM_IDCC)
         IF (ICC > 0) THEN
            DO JCC=1,MESHES(NOM)%CUT_CELL(ICC)%NCELL
               NCC_SV(NOM)=NCC_SV(NOM)+1
               MESHES(NOM)%CUT_CELL(ICC)%UNKZ(JCC) = M%OMESH(NOM)%UNKZ_CC_R(NCC_SV(NOM))
            ENDDO
         ENDIF
      ENDIF
   ENDDO EXTERNAL_WALL_LOOP_2
ENDDO
DEALLOCATE(NCC_SV)

! Finally Exchange Cartesian cell UNKZ:
IF (N_MPI_PROCESSES>1) THEN
   DO NM=1,NMESHES
      IF (MPI_COMM_MESH(NM)==MPI_COMM_NULL) CYCLE
      M => MESHES(NM)
      IF (EVACUATION_ONLY(NM)) CYCLE
      ! X direction bounds:
      ILO_FACE = 0                    ! Low mesh boundary face index.
      IHI_FACE = M%IBAR               ! High mesh boundary face index.
      ISTR     = ILO_FACE - NGUARD    ! Allocation start x arrays.
      IEND     = IHI_FACE + NGUARD    ! Allocation end x arrays.

      ! Y direction bounds:
      JLO_FACE = 0                    ! Low mesh boundary face index.
      JHI_FACE = M%JBAR               ! High mesh boundary face index.
      JSTR     = JLO_FACE - NGUARD    ! Allocation start y arrays.
      JEND     = JHI_FACE + NGUARD    ! Allocation end y arrays.

      ! Z direction bounds:
      KLO_FACE = 0                    ! Low mesh boundary face index.
      KHI_FACE = M%KBAR               ! High mesh boundary face index.
      KSTR     = KLO_FACE - NGUARD    ! Allocation start z arrays.
      KEND     = KHI_FACE + NGUARD    ! Allocation end z arrays.

      ALL_FLG = .FALSE.
      IF (.NOT.ALLOCATED(M%CCVAR)) THEN; ALL_FLG=.TRUE.; ALLOCATE(M%CCVAR(ISTR:IEND,JSTR:JEND,KSTR:KEND,IBM_UNKZ:IBM_UNKZ)); ENDIF
      N_INT = (IEND-ISTR+1)*(JEND-JSTR+1)*(KEND-KSTR+1)
      CALL MPI_BCAST(M%CCVAR(ISTR,JSTR,KSTR,IBM_UNKZ),N_INT,MPI_INTEGER,MPI_COMM_MESH_ROOT(NM),MPI_COMM_MESH(NM),IERR)
      IF (ALL_FLG) DEALLOCATE(M%CCVAR)
   ENDDO
ENDIF

IF (N_MPI_PROCESSES>1) THEN
   DEALLOCATE(REQ0)
   CALL MPI_BARRIER(MPI_COMM_WORLD,IERR)
ENDIF

RETURN
END SUBROUTINE FILL_UNKZ_GUARDCELLS

! ----------------------------- GET_CC_UNKH ------------------------------------

SUBROUTINE GET_CC_UNKH(I,J,K,IUNKH)

INTEGER, INTENT(IN) :: I,J,K
INTEGER, INTENT(OUT):: IUNKH

! Local variable:
INTEGER :: ICC

IUNKH    = IBM_UNDEFINED ! This is < 0.
! Second if PRES_ON_CARTESIAN = .FALSE. populate HP for cut-cells:
IF (.NOT.PRES_ON_CARTESIAN) THEN

   ! Code here refers to a fully unstructured pressure solver where each cut-cell has an independent
   ! pressure unknown, as is the case with scalars advection.
   ! To do.

ELSEIF (PRES_ON_CARTESIAN .AND. .NOT.PRES_ON_WHOLE_DOMAIN ) THEN

   ! Regular gas cell, taken care of before.
   ! Check cut-cell:
   ICC = CCVAR(I,J,K,IBM_IDCC)
   ! If theres is a cut-cell ICC then CUT_CELL(ICC)%UNKH(1) has been populated.
   IF (ICC > 0) IUNKH = CUT_CELL(ICC)%UNKH(1)

ENDIF


RETURN
END SUBROUTINE GET_CC_UNKH


! ----------------------------- GET_CC_IROW ------------------------------------

SUBROUTINE GET_CC_IROW(I,J,K,IROW)

INTEGER, INTENT(IN) :: I,J,K
INTEGER, INTENT(OUT):: IROW

! Local variable:
INTEGER :: ICC

IROW    = IBM_UNDEFINED ! This is < 0.
! Second if PRES_ON_CARTESIAN = .FALSE. populate HP for cut-cells:
IF (.NOT.PRES_ON_CARTESIAN) THEN

   ! Code here refers to a fully unstructured pressure solver where each cut-cell has an independent
   ! pressure unknown, as is the case with scalars advection.
   ! To do.

ELSEIF (PRES_ON_CARTESIAN .AND. .NOT.PRES_ON_WHOLE_DOMAIN ) THEN

   ! Regular gas cell, taken care of before.
   ! Check cut-cell:
   ICC = CCVAR(I,J,K,IBM_IDCC)
   ! If theres is a cut-cell ICC then CUT_CELL(ICC)%UNKH(1) has been populated.
   IF (ICC > 0) IROW     = CUT_CELL(ICC)%UNKH(1) - UNKH_IND(NM_START)

ENDIF


RETURN
END SUBROUTINE GET_CC_IROW

! ----------------------------- GET_CUTCELL_HP ------------------------------------


SUBROUTINE GET_CUTCELL_HP(NM,HP)

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(INOUT), POINTER, DIMENSION(:,:,:) :: HP

! Local Variables:
INTEGER :: I,J,K,IROW,ICC

! Second if PRES_ON_CARTESIAN = .FALSE. populate HP for cut-cells:
IF (.NOT.PRES_ON_CARTESIAN) THEN

   ! Code here refers to a fully unstructured pressure solver where each cut-cell has an independent
   ! pressure unknown, as is the case with scalars advection.
   ! To do.

ELSEIF (PRES_ON_CARTESIAN .AND. .NOT.PRES_ON_WHOLE_DOMAIN ) THEN

   CUTCELL_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH

      I = MESHES(NM)%CUT_CELL(ICC)%IJK(IAXIS)
      J = MESHES(NM)%CUT_CELL(ICC)%IJK(JAXIS)
      K = MESHES(NM)%CUT_CELL(ICC)%IJK(KAXIS)

      IROW     = MESHES(NM)%CUT_CELL(ICC)%UNKH(1) - UNKH_IND(NM_START)

      ! Assign to HP:
      HP(I,J,K) = -X_H(IROW)

   ENDDO CUTCELL_LOOP

ENDIF


RETURN
END SUBROUTINE GET_CUTCELL_HP

! ----------------------------- GET_CUTCELL_FH ------------------------------------

SUBROUTINE GET_CUTCELL_FH(NM)

INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER :: I,J,K,IROW,ICC

! Second if PRES_ON_CARTESIAN = .FALSE. populate source for cut-cells:
IF (.NOT.PRES_ON_CARTESIAN) THEN

   ! WORK HERE !!!! EITHER USE IBM FN on cut-faces or FVX, FVY, FVZ on regular faces
   ! of cut-cells. Compute integral on boundary cut faces (Div Theorem).

ELSEIF (PRES_ON_CARTESIAN .AND. .NOT.PRES_ON_WHOLE_DOMAIN ) THEN

   ! FVX(I,J,K), FVY(I,J,K), FVZ(I,J,K) have been populated for Cartesian faces which
   ! underlay gasphase cut-faces. They have also been populated on IBM_SOLID type , and regular faces.
   ! We use these values directly to define the div(F) term, rhs of Poisson in Cartesian cells of type
   ! IBM_CUTCFE. Their divergence has been added to PRHS in routine PRESSURE_SOLVER:
   CUTCELL_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH

      I = MESHES(NM)%CUT_CELL(ICC)%IJK(IAXIS)
      J = MESHES(NM)%CUT_CELL(ICC)%IJK(JAXIS)
      K = MESHES(NM)%CUT_CELL(ICC)%IJK(KAXIS)

      IROW     = MESHES(NM)%CUT_CELL(ICC)%UNKH(1) - UNKH_IND(NM_START)

      ! This might have the buoyancy div term DDDT wrong !!! - CHECK -

      ! Add to F_H:
      F_H(IROW) = F_H(IROW) + PRHS(I,J,K) * DX(I)*DY(J)*DZ(K)

   ENDDO CUTCELL_LOOP

ENDIF


RETURN
END SUBROUTINE GET_CUTCELL_FH

! ---------------------------- GET_H_MATRIX_CC ------------------------------------

SUBROUTINE GET_H_MATRIX_CC(NM,NM1,D_MAT_HP)

! This routine assumes the calling subroutine has called POINT_TO_MESH for NM.

INTEGER, INTENT(IN) :: NM,NM1
REAL(EB), POINTER, DIMENSION(:,:) :: D_MAT_HP

! Local Variables:
INTEGER :: X1AXIS,IFACE,ICF,I,J,K,IND(LOW_IND:HIGH_IND),IND_LOC(LOW_IND:HIGH_IND)
INTEGER :: LOCROW_1,LOCROW_2,ILOC,JLOC,JCOL,IROW,IW
REAL(EB) :: AF,IDX,BIJ,KFACE(2,2)
TYPE(WALL_TYPE), POINTER :: WC=>NULL()

IF (.NOT. ASSOCIATED(D_MAT_HP)) THEN
   WRITE(LU_ERR,*) 'GET_H_MATRIX_CC in geom.f90: Pointer D_MAT_HP not associated.'
   RETURN
ENDIF

IF ( PRES_ON_WHOLE_DOMAIN ) RETURN ! No cut-cell related info needed.

! X direction bounds:
ILO_FACE = 0                ! Low mesh boundary face index.
IHI_FACE = IBAR             ! High mesh boundary face index.
ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
IHI_CELL = IHI_FACE         ! Last internal cell index.

! Y direction bounds:
JLO_FACE = 0                ! Low mesh boundary face index.
JHI_FACE = JBAR             ! High mesh boundary face index.
JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
JHI_CELL = JHI_FACE         ! Last internal cell index.

! Z direction bounds:
KLO_FACE = 0                ! Low mesh boundary face index.
KHI_FACE = KBAR             ! High mesh boundary face index.
KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
KHI_CELL = KHI_FACE         ! Last internal cell index.

! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
DO IFACE=1,MESHES(NM)%IBM_NRCFACE_H

   I      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(IAXIS)
   J      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(JAXIS)
   K      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS)
   X1AXIS = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS+1)

   ! Unknowns on related cells:
   IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(LOW_IND)
   IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(HIGH_IND)

   IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! All row indexes must refer to ind_loc.
   IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)

   ! Row ind(1),ind(2):
   LOCROW_1 = LOW_IND
   LOCROW_2 = HIGH_IND
   SELECT CASE(X1AXIS)
      CASE(IAXIS)
         AF = DY(J)*DZ(K)
         IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
         IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
      CASE(JAXIS)
         AF = DX(I)*DZ(K)
         IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
         IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
      CASE(KAXIS)
         AF = DX(I)*DY(J)
         IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
         IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
   ENDSELECT

   IDX = 1._EB / ( MESHES(NM)%IBM_RCFACE_H(IFACE)%XCEN(X1AXIS,HIGH_IND) - &
                   MESHES(NM)%IBM_RCFACE_H(IFACE)%XCEN(X1AXIS,LOW_IND) )

   ! Now add to Adiff corresponding coeff:
   BIJ   = IDX*AF

   !    Cols 1,2: ind(LOW_IND) ind(HIGH_IND), Rows 1,2: ind_loc(LOW_IND) ind_loc(HIGH_IND)
   KFACE(1,1) = BIJ; KFACE(2,1) =-BIJ; KFACE(1,2) =-BIJ; KFACE(2,2) = BIJ

   DO ILOC=LOCROW_1,LOCROW_2   ! Local row number in Kface
      DO JLOC=LOW_IND,HIGH_IND ! Local col number in Kface, JD
          IROW=IND_LOC(ILOC)                                ! Process Local Unknown number.
          JCOL=MESHES(NM)%IBM_RCFACE_H(IFACE)%JD(ILOC,JLOC) ! Local position of coef in D_MAT_H
          ! Add coefficient:
          D_MAT_HP(JCOL,IROW) = D_MAT_HP(JCOL,IROW) + KFACE(ILOC,JLOC)
      ENDDO
   ENDDO

ENDDO

! Now Gasphase CUT_FACES:
IF ( .NOT.PRES_ON_CARTESIAN ) THEN

   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

      IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
      ! Drop if cut-face on a wall-cell, and type different than INTERPOLATED_BOUNDARY or PERIODIC_BOUNDARY.
      IW=MESHES(NM)%CUT_FACE(ICF)%IWC
      IF( IW > 0 ) THEN
         WC=>WALL(IW)
         IF (.NOT.( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                    WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) ) CYCLE
      ENDIF
      I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
      J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
      K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(JAXIS)
            IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(KAXIS)
            IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
      ENDSELECT

      DO IFACE=1,MESHES(NM)%CUT_FACE(ICF)%NFACE

         !% Unknowns on related cells:
         IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
         IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)

         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! All row indexes must refer to ind_loc.
         IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)

         AF = MESHES(NM)%CUT_FACE(ICF)%AREA(IFACE)
         IDX= 1._EB/ ( MESHES(NM)%CUT_FACE(ICF)%XCENHIGH(X1AXIS,IFACE) - &
                       MESHES(NM)%CUT_FACE(ICF)%XCENLOW(X1AXIS, IFACE) )

         ! Now add to Adiff corresponding coeff:
         BIJ   = IDX*AF

         !    Cols 1,2: ind(LOW_IND) ind(HIGH_IND), Rows 1,2: ind_loc(LOW_IND) ind_loc(HIGH_IND)
         KFACE(1,1) = BIJ; KFACE(2,1) =-BIJ; KFACE(1,2) =-BIJ; KFACE(2,2) = BIJ

         DO ILOC=LOCROW_1,LOCROW_2 ! Local row number in Kface
            DO JLOC=LOW_IND,HIGH_IND ! Local col number in Kface, JD
                IROW=IND_LOC(ILOC)
                JCOL=MESHES(NM)%CUT_FACE(ICF)%JDH(ILOC,JLOC,IFACE)
                ! Add coefficient:
                D_MAT_HP(JCOL,IROW) = D_MAT_HP(JCOL,IROW) + KFACE(ILOC,JLOC)
            ENDDO
         ENDDO

      ENDDO

   ENDDO

ELSE ! PRES_ON_CARTESIAN

   DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

      IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
      ! Drop if cut-face on a wall-cell, and type different than INTERPOLATED_BOUNDARY or PERIODIC_BOUNDARY.
      IW=MESHES(NM)%CUT_FACE(ICF)%IWC
      IF( IW > 0 ) THEN
         WC=>WALL(IW)
         IF (.NOT.( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                    WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) ) CYCLE
      ENDIF
      I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
      J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
      K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)

      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            AF = DY(J)*DZ(K)
            IDX= 1._EB/DXN(I)
            IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(JAXIS)
            AF = DX(I)*DZ(K)
            IDX= 1._EB/DYN(J)
            IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(KAXIS)
            AF = DX(I)*DY(J)
            IDX= 1._EB/DZN(K)
            IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
      ENDSELECT

      IFACE = 1 ! First location for UNKH has the unique H unknown
                ! for the cut-cells underlying Cartesian cell.

      !% Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
      IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)

      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! All row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)

      ! Now add to Adiff corresponding coeff:
      BIJ   = IDX*AF

      !    Cols 1,2: ind(LOW_IND) ind(HIGH_IND), Rows 1,2: ind_loc(LOW_IND) ind_loc(HIGH_IND)
      KFACE(1,1) = BIJ; KFACE(2,1) =-BIJ; KFACE(1,2) =-BIJ; KFACE(2,2) = BIJ

      DO ILOC=LOCROW_1,LOCROW_2 ! Local row number in Kface
         DO JLOC=LOW_IND,HIGH_IND ! Local col number in Kface, JD
             IROW=IND_LOC(ILOC)
             JCOL=MESHES(NM)%CUT_FACE(ICF)%JDH(ILOC,JLOC,IFACE)
             ! Add coefficient:
             D_MAT_HP(JCOL,IROW) = D_MAT_HP(JCOL,IROW) + KFACE(ILOC,JLOC)
         ENDDO
      ENDDO

   ENDDO

ENDIF

RETURN
END SUBROUTINE GET_H_MATRIX_CC


! -------------------------- GET_CC_MATRIXGRAPH_H ---------------------------------

SUBROUTINE GET_CC_MATRIXGRAPH_H(NM,NM1,LOOP_FLAG)

INTEGER, INTENT(IN) :: NM,NM1
LOGICAL, INTENT(IN) :: LOOP_FLAG

! Local Variables:
INTEGER :: X1AXIS,IFACE,ICF,I,J,K,IND(LOW_IND:HIGH_IND),IND_LOC(LOW_IND:HIGH_IND)
INTEGER :: LOCROW_1,LOCROW_2,LOCROW,IIND,NII,ILOC,IW
TYPE(WALL_TYPE), POINTER :: WC=>NULL()

IF ( PRES_ON_WHOLE_DOMAIN ) RETURN ! No need to deal with cut-faces.

! X direction bounds:
ILO_FACE = 0                    ! Low mesh boundary face index.
IHI_FACE = MESHES(NM)%IBAR      ! High mesh boundary face index.
ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
IHI_CELL = IHI_FACE ! Last internal cell index.

! Y direction bounds:
JLO_FACE = 0                    ! Low mesh boundary face index.
JHI_FACE = MESHES(NM)%JBAR      ! High mesh boundary face index.
JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
JHI_CELL = JHI_FACE ! Last internal cell index.

! Z direction bounds:
KLO_FACE = 0                    ! Low mesh boundary face index.
KHI_FACE = MESHES(NM)%KBAR      ! High mesh boundary face index.
KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
KHI_CELL = KHI_FACE ! Last internal cell index.


LOOP_FLAG_COND : IF ( LOOP_FLAG ) THEN ! MESH_LOOP_1 in calling routine.

   ! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   DO IFACE=1,MESHES(NM)%IBM_NRCFACE_H
      I      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(IAXIS)
      J      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(JAXIS)
      K      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS+1)
      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(LOW_IND)
      IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(HIGH_IND)
      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! Row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)
      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(JAXIS)
            IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(KAXIS)
            IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
      ENDSELECT
      ! Add to global matrix arrays:
      CALL ADD_INPLACE_NNZ_H_WHLDOM(LOCROW_1,LOCROW_2,IND,IND_LOC)
   ENDDO

   IF ( .NOT.PRES_ON_CARTESIAN ) THEN
      DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
         IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
         ! Drop if cut-face on a wall-cell, and type different than INTERPOLATED_BOUNDARY or PERIODIC_BOUNDARY.
         IW=MESHES(NM)%CUT_FACE(ICF)%IWC
         IF( IW > 0 ) THEN
            WC=>WALL(IW)
            IF (.NOT.( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                       WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) ) CYCLE
         ENDIF
         I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
         J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
         K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
         X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)
         ! Row ind(1),ind(2):
         LOCROW_1 = LOW_IND
         LOCROW_2 = HIGH_IND
         SELECT CASE(X1AXIS)
            CASE(IAXIS)
               IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(JAXIS)
               IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(KAXIS)
               IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
         ENDSELECT
         DO IFACE=1,MESHES(NM)%CUT_FACE(ICF)%NFACE
            !% Unknowns on related cells:
            IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
            IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)
            IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! Row indexes refer to ind_loc.
            IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)
            ! Add to global matrix arrays:
            CALL ADD_INPLACE_NNZ_H_WHLDOM(LOCROW_1,LOCROW_2,IND,IND_LOC)
         ENDDO
      ENDDO
   ELSE ! PRES_ON_CARTESIAN
      DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH

         IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
         ! Drop if cut-face on a wall-cell, and type different than INTERPOLATED_BOUNDARY or PERIODIC_BOUNDARY.
         IW=MESHES(NM)%CUT_FACE(ICF)%IWC
         IF( IW > 0 ) THEN
            WC=>WALL(IW)
            IF (.NOT.( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                       WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) ) CYCLE
         ENDIF
         I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
         J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
         K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
         X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)
         ! Row ind(1),ind(2):
         LOCROW_1 = LOW_IND
         LOCROW_2 = HIGH_IND
         SELECT CASE(X1AXIS)
            CASE(IAXIS)
               IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(JAXIS)
               IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(KAXIS)
               IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
         ENDSELECT
         IFACE = 1 ! First location for UNKH has the unique H unknown
                   ! for the cut-cells underlying Cartesian cell.
         ! Unknowns on related cells:
         IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
         IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)
         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! row indexes refer to ind_loc.
         IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)
         ! Add to global matrix arrays:
         CALL ADD_INPLACE_NNZ_H_WHLDOM(LOCROW_1,LOCROW_2,IND,IND_LOC)
      ENDDO
   ENDIF

   ! Somewhere here should have the contribution of IBM_INBOUNDARY cut-faces,
   ! for Dirichlet BCs:
   !!!

ELSE ! MESH_LOOP_2 in calling routine.

   ! Regular faces connecting gasphase-gasphase or gasphase- cut-cells:
   DO IFACE=1,MESHES(NM)%IBM_NRCFACE_H
      I      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(IAXIS)
      J      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(JAXIS)
      K      = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS)
      X1AXIS = MESHES(NM)%IBM_RCFACE_H(IFACE)%IJK(KAXIS+1)
      ! Unknowns on related cells:
      IND(LOW_IND)  = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(LOW_IND)
      IND(HIGH_IND) = MESHES(NM)%IBM_RCFACE_H(IFACE)%UNK(HIGH_IND)
      IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! Row indexes must refer to ind_loc.
      IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)
      ! Row ind(1),ind(2):
      LOCROW_1 = LOW_IND
      LOCROW_2 = HIGH_IND
      SELECT CASE(X1AXIS)
         CASE(IAXIS)
            IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(JAXIS)
            IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
         CASE(KAXIS)
            IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
            IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
      ENDSELECT
      MESHES(NM)%IBM_RCFACE_H(IFACE)%JD(1:2,1:2) = 0
      ! Add to global matrix arrays:
      DO LOCROW=LOCROW_1,LOCROW_2
         DO IIND=LOW_IND,HIGH_IND
            NII = NNZ_D_MAT_H(IND_LOC(LOCROW))
            DO ILOC=1,NII
               IF ( IND(IIND) == JD_MAT_H(ILOC,IND_LOC(LOCROW)) ) THEN
                   MESHES(NM)%IBM_RCFACE_H(IFACE)%JD(LOCROW,IIND) = ILOC
                   EXIT
               ENDIF
            ENDDO
         ENDDO
      ENDDO
   ENDDO

   IF ( .NOT.PRES_ON_CARTESIAN ) THEN
      ! Now Gasphase CUT_FACES:
      DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
         IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
         ! Drop if cut-face on a wall-cell, and type different than INTERPOLATED_BOUNDARY or PERIODIC_BOUNDARY.
         IW=MESHES(NM)%CUT_FACE(ICF)%IWC
         IF( IW > 0 ) THEN
            WC=>WALL(IW)
            IF (.NOT.( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                       WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) ) CYCLE
         ENDIF
         I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
         J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
         K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
         X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)
         ! Row ind(1),ind(2):
         LOCROW_1 = LOW_IND
         LOCROW_2 = HIGH_IND
         SELECT CASE(X1AXIS)
            CASE(IAXIS)
               IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(JAXIS)
               IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(KAXIS)
               IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
         ENDSELECT
         MESHES(NM)%CUT_FACE(ICF)%JDH(:,:,:) = 0
         DO IFACE=1,MESHES(NM)%CUT_FACE(ICF)%NFACE
            !% Unknowns on related cells:
            IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
            IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)
            IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! Row indexes refer to ind_loc.
            IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)
            ! Add to global matrix arrays:
            DO LOCROW=LOCROW_1,LOCROW_2
               DO IIND=LOW_IND,HIGH_IND
                  NII = NNZ_D_MAT_H(IND_LOC(LOCROW))
                  DO ILOC=1,NII
                     IF ( IND(IIND) == JD_MAT_H(ILOC,IND_LOC(LOCROW)) ) THEN
                         MESHES(NM)%CUT_FACE(ICF)%JDH(LOCROW,IIND,IFACE) = ILOC
                         EXIT
                     ENDIF
                  ENDDO
               ENDDO
            ENDDO
         ENDDO
      ENDDO

   ELSE ! PRES_ON_CARTESIAN

      ! Now Gasphase CUT_FACES:
      DO ICF = 1,MESHES(NM)%N_CUTFACE_MESH
         IF ( MESHES(NM)%CUT_FACE(ICF)%STATUS /= IBM_GASPHASE ) CYCLE
         ! Drop if cut-face on a wall-cell, and type different than INTERPOLATED_BOUNDARY or PERIODIC_BOUNDARY.
         IW=MESHES(NM)%CUT_FACE(ICF)%IWC
         IF( IW > 0 ) THEN
            WC=>WALL(IW)
            IF (.NOT.( WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. &
                       WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY ) ) CYCLE
         ENDIF
         I = MESHES(NM)%CUT_FACE(ICF)%IJK(IAXIS)
         J = MESHES(NM)%CUT_FACE(ICF)%IJK(JAXIS)
         K = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS)
         X1AXIS = MESHES(NM)%CUT_FACE(ICF)%IJK(KAXIS+1)
         ! Row ind(1),ind(2):
         LOCROW_1 = LOW_IND
         LOCROW_2 = HIGH_IND
         SELECT CASE(X1AXIS)
            CASE(IAXIS)
               IF ( I == ILO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( I == IHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(JAXIS)
               IF ( J == JLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( J == JHI_FACE ) LOCROW_2 =  LOW_IND ! Only low side unknown row.
            CASE(KAXIS)
               IF ( K == KLO_FACE ) LOCROW_1 = HIGH_IND ! Only high side unknown row.
               IF ( K == KHI_FACE)  LOCROW_2 =  LOW_IND ! Only low side unknown row.
         ENDSELECT
         MESHES(NM)%CUT_FACE(ICF)%JDH(:,:,:) = 0
         IFACE = 1
         !% Unknowns on related cells:
         IND(LOW_IND)  = MESHES(NM)%CUT_FACE(ICF)%UNKH(LOW_IND,IFACE)
         IND(HIGH_IND) = MESHES(NM)%CUT_FACE(ICF)%UNKH(HIGH_IND,IFACE)
         IND_LOC(LOW_IND) = IND(LOW_IND) - UNKH_IND(NM1) ! Row indexes refer to ind_loc.
         IND_LOC(HIGH_IND)= IND(HIGH_IND)- UNKH_IND(NM1)
         ! Add to global matrix arrays:
         DO LOCROW=LOCROW_1,LOCROW_2
            DO IIND=LOW_IND,HIGH_IND
               NII = NNZ_D_MAT_H(IND_LOC(LOCROW))
               DO ILOC=1,NII
                  IF ( IND(IIND) == JD_MAT_H(ILOC,IND_LOC(LOCROW)) ) THEN
                      MESHES(NM)%CUT_FACE(ICF)%JDH(LOCROW,IIND,IFACE) = ILOC
                      EXIT
                  ENDIF
               ENDDO
            ENDDO
         ENDDO
      ENDDO
   ENDIF

   ! Somewhere here should have the contribution of IBM_INBOUNDARY cut-faces, for Dirichlet BCs:
   !!!

ENDIF LOOP_FLAG_COND

RETURN
END SUBROUTINE GET_CC_MATRIXGRAPH_H

! ------------------------ ADD_INPLACE_NNZ_H_WHLDOM -------------------------------

SUBROUTINE ADD_INPLACE_NNZ_H_WHLDOM(LOCROW_1,LOCROW_2,IND,IND_LOC)

INTEGER, INTENT(IN) :: LOCROW_1,LOCROW_2,IND(LOW_IND:HIGH_IND),IND_LOC(LOW_IND:HIGH_IND)

! Local Variables:
INTEGER LOCROW, IIND, NII, ILOC, JLOC
LOGICAL INLIST

LOCROW_LOOP : DO LOCROW=LOCROW_1,LOCROW_2
   DO IIND=LOW_IND,HIGH_IND
      NII = NNZ_D_MAT_H(IND_LOC(LOCROW))
      ! Check that column index hasn't been already counted:
      INLIST = .FALSE.
      DO ILOC=1,NII
         IF ( IND(IIND) == JD_MAT_H(ILOC,IND_LOC(LOCROW)) ) THEN
            INLIST = .TRUE.
            EXIT
         ENDIF
      ENDDO
      IF ( INLIST ) CYCLE

      ! Now add in place:
      NII = NII + 1
      DO ILOC=1,NII
          IF ( JD_MAT_H(ILOC,IND_LOC(LOCROW)) > IND(IIND) ) EXIT
      ENDDO
      DO JLOC=NII,ILOC+1,-1
          JD_MAT_H(JLOC,IND_LOC(LOCROW)) = JD_MAT_H(JLOC-1,IND_LOC(LOCROW))
      ENDDO
      NNZ_D_MAT_H(IND_LOC(LOCROW))   = NII
      JD_MAT_H(ILOC,IND_LOC(LOCROW)) = IND(IIND)
   ENDDO
ENDDO LOCROW_LOOP

RETURN
END SUBROUTINE ADD_INPLACE_NNZ_H_WHLDOM


! --------------------------- GET_MMATRIX_SCALAR_3D -------------------------------

SUBROUTINE GET_MMATRIX_SCALAR_3D


! Local Variables:
INTEGER :: NM
INTEGER :: I,J,K,IROW,IROW_LOC,ICC,ICC2

! Allocate mass matrix: Diagonal containing cell volumes on implicit region:
ALLOCATE(  M_MAT_Z(1:NUNKZ_LOCAL) );  M_MAT_Z = 0._EB
ALLOCATE( JM_MAT_Z(1:NUNKZ_LOCAL) ); JM_MAT_Z = 0 ! local index of diagonal entry in JD_MAT_Z

! Mesh Loop:
MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.
   ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
   IHI_CELL = IHI_FACE ! Last internal cell index.

   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.
   JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
   JHI_CELL = JHI_FACE ! Last internal cell index.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.
   KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
   KHI_CELL = KHI_FACE ! Last internal cell index.


   ! 1. Number Regular GASPHASE cells:
   DO K=KLO_CELL,KHI_CELL
      DO J=JLO_CELL,JHI_CELL
         DO I=ILO_CELL,IHI_CELL
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0) CYCLE ! Either explicit region or solid cell.
            IROW = CCVAR(I,J,K,IBM_UNKZ)
            IROW_LOC = IROW - UNKZ_IND(NM_START)
            M_MAT_Z(IROW_LOC) = M_MAT_Z(IROW_LOC) + DX(I)*DY(J)*DZ(K)
         ENDDO
      ENDDO
   ENDDO

   ! 2. Now Cut cells:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      I = CUT_CELL(ICC)%IJK(IAXIS)
      J = CUT_CELL(ICC)%IJK(JAXIS)
      K = CUT_CELL(ICC)%IJK(KAXIS)
      ! Drop cut-cells inside an OBST:
      IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
      DO ICC2 = 1,CUT_CELL(ICC)%NCELL
         IROW     = CUT_CELL(ICC)%UNKZ(ICC2)
         IROW_LOC = IROW - UNKZ_IND(NM_START)
         IF(CUT_CELL(ICC)%USE_CC_VOL(ICC2)) THEN
            M_MAT_Z(IROW_LOC) = M_MAT_Z(IROW_LOC) + CUT_CELL(ICC)%VOLUME(ICC2)
         ELSE
            I = CUT_CELL(ICC)%IJK(IAXIS)
            J = CUT_CELL(ICC)%IJK(JAXIS)
            K = CUT_CELL(ICC)%IJK(KAXIS)
            M_MAT_Z(IROW_LOC) = M_MAT_Z(IROW_LOC) + CCVOL_LINK*DX(I)*DY(J)*DZ(K) ! Set cut-cell volume to threshold
                                                                                 ! volume for stability.
         ENDIF
      ENDDO
   ENDDO

ENDDO MESH_LOOP

RETURN
END SUBROUTINE GET_MMATRIX_SCALAR_3D


! --------------------------- GET_H_CUTFACES ------------------------------------

SUBROUTINE GET_H_CUTFACES

! Local variables:
INTEGER :: NM
INTEGER :: NCELL,ICC,JCC,IFC,IFACE,LOWHIGH,ICF1,ICF2
INTEGER :: IW,II,JJ,KK,IIF,JJF,KKF,IOR,LOWHIGH_TEST,X1AXIS
TYPE (WALL_TYPE), POINTER :: WC

! Mesh loop:
MAIN_MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! Now Pressure:
   if ( PRES_ON_WHOLE_DOMAIN ) CYCLE ! No need to build matrix this way, i.e. fft solver/structured solve
                                     ! will be used for pressure.

   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      NCELL = CUT_CELL(ICC)%NCELL
      DO JCC=1,NCELL
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! If face type in face_list is not IBM_FTYPE_CFGAS, drop:
            IF ( CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_CFGAS ) CYCLE

            ! Which face?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            ICF1    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
            ICF2    = CUT_CELL(ICC)%FACE_LIST(5,IFACE)

            IF ( LOWHIGH == LOW_IND) THEN ! Cut-face on low side of cut-cell:

               IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured H Poisson matrix build, use cut-cell vols:
                  CUT_FACE(ICF1)%UNKH(HIGH_IND,ICF2) = CUT_CELL(ICC)%UNKH(JCC)
                  !  XCENH already filled in scalars.

               ELSE ! Unstructured build, use underlying cartesian cells:
                  CUT_FACE(ICF1)%UNKH(HIGH_IND,ICF2) = CUT_CELL(ICC)%UNKH(1)
                  !  XCENH is the Cartesian cell center of high side cell.

               ENDIF

            ELSE ! HIGH

               IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured H Poisson matrix build, use cut-cell vols:
                  CUT_FACE(ICF1)%UNKH(LOW_IND,ICF2) = CUT_CELL(ICC)%UNKH(JCC)
                  !  XCENL already filled in scalars.

               ELSE ! Unstructured build, use underlying cartesian cells:
                  CUT_FACE(ICF1)%UNKH(LOW_IND,ICF2) = CUT_CELL(ICC)%UNKH(1)
                  !  XCENL is the Cartesian cell center of the low side cell.
                  !  LOW_IND and HIGH_IND numbers will be repeated for all icf2 IBM_GASPHASE cut-faces.

               ENDIF

            ENDIF

         ENDDO
      ENDDO
   ENDDO

   ! Now Apply external wall cell loop for guard-cell cut cells:
   GUARD_CUT_CELL_LOOP :  DO IW=1,N_EXTERNAL_WALL_CELLS
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY) CYCLE GUARD_CUT_CELL_LOOP

      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK
      IOR = WC%ONE_D%IOR

      ! Drop if face is not of type IBM_CUTCFE:
      X1AXIS=ABS(IOR)
      SELECT CASE(IOR)
      CASE( IAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND ! Face on high side of Guard-Cell
      CASE(-IAXIS)
         IIF=II-1; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=LOW_IND
      CASE( JAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND
      CASE(-JAXIS)
         IIF=II  ; JJF=JJ-1; KKF=KK
         LOWHIGH_TEST=LOW_IND
      CASE( KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND
      CASE(-KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK-1
         LOWHIGH_TEST=LOW_IND
      END SELECT

      IF (FCVAR(IIF,JJF,KKF,IBM_FGSC,X1AXIS) /= IBM_CUTCFE) CYCLE GUARD_CUT_CELL_LOOP

      ! Copy CCVAR(II,JJ,KK,IBM_CGSC) to guard cell:
      ICC = MESHES(NM)%CCVAR(II,JJ,KK,IBM_IDCC)

      DO JCC=1,CUT_CELL(ICC)%NCELL

         ! Loop faces and test:
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)

            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! Which face ?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)

            IF ( CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_CFGAS) CYCLE ! Must Be gasphase cut-face
            IF ( LOWHIGH                              /= LOWHIGH_TEST) CYCLE ! In same side as EWC from guard-cell
            IF ( CUT_CELL(ICC)%FACE_LIST(3,IFACE) /= X1AXIS) CYCLE ! Normal to same axis as EWC

            ICF1    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
            ICF2    = CUT_CELL(ICC)%FACE_LIST(5,IFACE)

            IF ( LOWHIGH == LOW_IND) THEN ! Cut-face on low side of cut-cell:
               IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured H Poisson matrix build, use cut-cell vols:
                  CUT_FACE(ICF1)%UNKH(HIGH_IND,ICF2) = CUT_CELL(ICC)%UNKH(JCC)
               ELSE ! Unstructured build, use underlying cartesian cells:
                  CUT_FACE(ICF1)%UNKH(HIGH_IND,ICF2) = CUT_CELL(ICC)%UNKH(1)
               ENDIF
            ELSE ! HIGH
               IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured H Poisson matrix build, use cut-cell vols:
                  CUT_FACE(ICF1)%UNKH(LOW_IND,ICF2) = CUT_CELL(ICC)%UNKH(JCC)
               ELSE ! Unstructured build, use underlying cartesian cells:
                  CUT_FACE(ICF1)%UNKH(LOW_IND,ICF2) = CUT_CELL(ICC)%UNKH(1)
               ENDIF
            ENDIF

         ENDDO
      ENDDO
   ENDDO GUARD_CUT_CELL_LOOP

ENDDO MAIN_MESH_LOOP


RETURN
END SUBROUTINE GET_H_CUTFACES

! ---------------------- GET_GASPHASE_CUTFACES_DATA -----------------------------

SUBROUTINE GET_GASPHASE_CUTFACES_DATA

USE MPI_F08

! Local variables:
INTEGER :: NM
INTEGER :: NCELL,ICC,JCC,IFC,IFACE,LOWHIGH,ICF1,ICF2
INTEGER :: IW,II,JJ,KK,IIF,JJF,KKF,IOR,IIG,JJG,KKG,LOWHIGH_TEST,LOWHIGH_TEST_G,X1AXIS
TYPE (WALL_TYPE), POINTER :: WC
INTEGER :: IERR

! Mesh loop:
MAIN_MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! First Scalars:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      NCELL = CUT_CELL(ICC)%NCELL
      DO JCC=1,NCELL
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! If face type in face_list is not IBM_FTYPE_CFGAS, drop:
            IF ( CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_CFGAS ) CYCLE

            ! Which face?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            ICF1    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
            ICF2    = CUT_CELL(ICC)%FACE_LIST(5,IFACE)

            IF ( LOWHIGH == LOW_IND) THEN ! Cut-face on low side of cut-cell:

               CUT_FACE(ICF1)%UNKZ(HIGH_IND,ICF2)        = CUT_CELL(ICC)%UNKZ(JCC)
               CUT_FACE(ICF1)%XCENHIGH(IAXIS:KAXIS,ICF2) = CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)

            ELSE ! HIGH

               CUT_FACE(ICF1)%UNKZ(LOW_IND,ICF2)         = CUT_CELL(ICC)%UNKZ(JCC)
               CUT_FACE(ICF1)%XCENLOW(IAXIS:KAXIS,ICF2)  = CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)

            ENDIF

         ENDDO
      ENDDO
   ENDDO

   ! Now Apply external wall cell loop for guard-cell cut cells:
   GUARD_CUT_CELL_LOOP :  DO IW=1,N_EXTERNAL_WALL_CELLS
      WC=>WALL(IW)

      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK
      IOR = WC%ONE_D%IOR

      ! Drop if face is not of type IBM_CUTCFE:
      X1AXIS=ABS(IOR)
      SELECT CASE(IOR)
      CASE( IAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST  =HIGH_IND ! Face on high side of Guard-Cell
         LOWHIGH_TEST_G= LOW_IND
      CASE(-IAXIS)
         IIF=II-1; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST  = LOW_IND
         LOWHIGH_TEST_G=HIGH_IND
      CASE( JAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST  =HIGH_IND
         LOWHIGH_TEST_G= LOW_IND
      CASE(-JAXIS)
         IIF=II  ; JJF=JJ-1; KKF=KK
         LOWHIGH_TEST  = LOW_IND
         LOWHIGH_TEST_G=HIGH_IND
      CASE( KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST  =HIGH_IND
         LOWHIGH_TEST_G= LOW_IND
      CASE(-KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK-1
         LOWHIGH_TEST  = LOW_IND
         LOWHIGH_TEST_G=HIGH_IND
      END SELECT

      IF (FCVAR(IIF,JJF,KKF,IBM_FGSC,X1AXIS) /= IBM_CUTCFE) CYCLE GUARD_CUT_CELL_LOOP

      IIG  = WC%ONE_D%IIG
      JJG  = WC%ONE_D%JJG
      KKG  = WC%ONE_D%KKG

      ! Add IWC field to CUT_FACE from internal cell:
      ICC = MESHES(NM)%CCVAR(IIG,JJG,KKG,IBM_IDCC)
      DO JCC=1,CUT_CELL(ICC)%NCELL
         ! Loop faces and test:
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! Which face ?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            IF ( CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_CFGAS) CYCLE ! Must Be gasphase cut-face
            IF ( LOWHIGH                          /=  LOWHIGH_TEST_G) CYCLE ! In same side as EWC from internal cell
            IF ( CUT_CELL(ICC)%FACE_LIST(3,IFACE) /= X1AXIS) CYCLE ! Normal to same axis as EWC
            ICF1    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
            CUT_FACE(ICF1)%IWC = IW ! Rest of info from internal cut-cell has been filled in previous ICC loop.
         ENDDO
      ENDDO

      ! Now CCVAR(II,JJ,KK,IBM_CGSC) from guard cell:
      ICC = MESHES(NM)%CCVAR(II,JJ,KK,IBM_IDCC)
      DO JCC=1,CUT_CELL(ICC)%NCELL
         ! Loop faces and test:
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! Which face ?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            IF ( CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_CFGAS) CYCLE ! Must Be gasphase cut-face
            IF ( LOWHIGH                              /= LOWHIGH_TEST) CYCLE ! In same side as EWC from guard-cell
            IF ( CUT_CELL(ICC)%FACE_LIST(3,IFACE) /= X1AXIS) CYCLE ! Normal to same axis as EWC

            ICF1    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
            ICF2    = CUT_CELL(ICC)%FACE_LIST(5,IFACE)

            IF ( LOWHIGH == LOW_IND) THEN ! Cut-face on low side of cut-cell:
               CUT_FACE(ICF1)%UNKZ(HIGH_IND,ICF2)        = CUT_CELL(ICC)%UNKZ(JCC)
               CUT_FACE(ICF1)%XCENHIGH(IAXIS:KAXIS,ICF2) = CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
            ELSE ! HIGH
               CUT_FACE(ICF1)%UNKZ(LOW_IND,ICF2)         = CUT_CELL(ICC)%UNKZ(JCC)
               CUT_FACE(ICF1)%XCENLOW(IAXIS:KAXIS,ICF2)  = CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
            ENDIF

         ENDDO
      ENDDO
   ENDDO GUARD_CUT_CELL_LOOP

ENDDO MAIN_MESH_LOOP

IF (DEBUG_MATVEC_DATA) THEN
   DBG_MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
      IF(MY_RANK==PROCESS(NM)) THEN
      CALL POINT_TO_MESH(NM)
      WRITE(LU_ERR,*) ' '
      WRITE(LU_ERR,*) 'MY_RANK, NM, N_BBCUTFACE_MESH : ',MY_RANK,NM,MESHES(NM)%N_BBCUTFACE_MESH
      DO IFC=1,MESHES(NM)%N_BBCUTFACE_MESH
         IF(CUT_FACE(IFC)%STATUS/=IBM_GASPHASE) CYCLE
         WRITE(LU_ERR,*) 'BB CUT_FACE, IFC, IWC=',IFC,CUT_FACE(IFC)%IWC,CUT_FACE(IFC)%STATUS
      ENDDO
      ENDIF
      CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
   ENDDO DBG_MESH_LOOP
ENDIF

RETURN
END SUBROUTINE GET_GASPHASE_CUTFACES_DATA


! ---------------------------- GET_RCFACES_H ------------------------------------

SUBROUTINE GET_RCFACES_H(NM)


INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER :: IRC,IIFC,X1AXIS,X2AXIS,X3AXIS
INTEGER, ALLOCATABLE, DIMENSION(:,:,:,:) :: IJKFACE
INTEGER :: NCELL,ICC,JCC,IJK(MAX_DIM),IFC,IFACE,LOWHIGH
INTEGER :: XIAXIS,XJAXIS,XKAXIS,INDXI1(MAX_DIM),INCELL,JNCELL,KNCELL,INFACE,JNFACE,KNFACE
INTEGER :: ISTR, IEND, JSTR, JEND, KSTR, KEND
LOGICAL :: INLIST

INTEGER :: IW,II,JJ,KK,IIF,JJF,KKF,IOR,LOWHIGH_TEST,IIG,JJG,KKG
TYPE (WALL_TYPE), POINTER :: WC

LOGICAL :: FLGIN

! Test for Pressure Solver:
IF ( (PRES_METHOD /= "GLMAT") .OR. (PRES_ON_WHOLE_DOMAIN) ) RETURN ! No need to build matrix as
                                                                   ! unstructured.

! Mesh sizes:
NXB=IBAR; NYB=JBAR; NZB=KBAR

! X direction bounds:
ILO_FACE = 0                    ! Low mesh boundary face index.
IHI_FACE = IBAR                 ! High mesh boundary face index.
ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
IHI_CELL = IHI_FACE ! Last internal cell index.
ISTR     = ILO_FACE - NGUARD    ! Allocation start x arrays.
IEND     = IHI_FACE + NGUARD    ! Allocation end x arrays.

! Y direction bounds:
JLO_FACE = 0                    ! Low mesh boundary face index.
JHI_FACE = JBAR                 ! High mesh boundary face index.
JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
JHI_CELL = JHI_FACE ! Last internal cell index.
JSTR     = JLO_FACE - NGUARD    ! Allocation start y arrays.
JEND     = JHI_FACE + NGUARD    ! Allocation end y arrays.

! Z direction bounds:
KLO_FACE = 0                    ! Low mesh boundary face index.
KHI_FACE = KBAR                 ! High mesh boundary face index.
KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
KHI_CELL = KHI_FACE ! Last internal cell index.
KSTR     = KLO_FACE - NGUARD    ! Allocation start z arrays.
KEND     = KHI_FACE + NGUARD    ! Allocation end z arrays.

! First count for allocation:
ALLOCATE( IJKFACE(ILO_FACE:IHI_FACE,JLO_FACE:JHI_FACE,KLO_FACE:KHI_FACE,IAXIS:KAXIS) )
IJKFACE(:,:,:,:) = 0
DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
   NCELL = CUT_CELL(ICC)%NCELL
   IJK(IAXIS:KAXIS) = CUT_CELL(ICC)%IJK(IAXIS:KAXIS)
   DO JCC=1,NCELL
      ! Loop faces and test:
      DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
         IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
         ! If face type in face_list is not IBM_FTYPE_RGGAS, drop:
         IF(CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_RGGAS) CYCLE
         ! Which face?
         LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
         X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)
         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            X2AXIS = JAXIS; X3AXIS = KAXIS
            ! location in I,J,K od x2,x2,x3 axes:
            XIAXIS = IAXIS; XJAXIS = JAXIS; XKAXIS = KAXIS
         CASE(JAXIS)
            X2AXIS = KAXIS; X3AXIS = IAXIS
            ! location in I,J,K od x2,x2,x3 axes:
            XIAXIS = KAXIS; XJAXIS = IAXIS; XKAXIS = JAXIS
         CASE(KAXIS)
            X2AXIS = IAXIS; X3AXIS = JAXIS
            ! location in I,J,K od x2,x2,x3 axes:
            XIAXIS = JAXIS; XJAXIS = KAXIS; XKAXIS = IAXIS
         END SELECT

         IF (LOWHIGH == LOW_IND) THEN
            ! Face indexes:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
            INFACE = INDXI1(XIAXIS)
            JNFACE = INDXI1(XJAXIS)
            KNFACE = INDXI1(XKAXIS)

            ! Location of next Cartesian cell:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
            INCELL = INDXI1(XIAXIS)
            JNCELL = INDXI1(XJAXIS)
            KNCELL = INDXI1(XKAXIS)

            IF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH) > 0 ) THEN
               IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS) = 1
            ELSEIF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE ) THEN ! Cut-cell.
               IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS) = 1
            ENDIF
         ELSE ! HIGH_IND
            ! Face indexes:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS), IJK(X2AXIS), IJK(X3AXIS) /)
            INFACE = INDXI1(XIAXIS)
            JNFACE = INDXI1(XJAXIS)
            KNFACE = INDXI1(XKAXIS)

            ! Location of next Cartesian cell:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)+1, IJK(X2AXIS), IJK(X3AXIS) /)
            INCELL = INDXI1(XIAXIS)
            JNCELL = INDXI1(XJAXIS)
            KNCELL = INDXI1(XKAXIS)

            IF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH) > 0 ) THEN
               IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS) = 1
            ELSEIF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE ) THEN ! Cut-cell.
               IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS) = 1
            ENDIF
         ENDIF

      ENDDO
   ENDDO
ENDDO

! Check for RCFACE_H on the boundary of the domain, where the cut-cell is in the cut-cell region.
! Now Apply external wall cell loop for guard-cell cut cells:
GUARD_CUT_CELL_LOOP_1 :  DO IW=1,N_EXTERNAL_WALL_CELLS
   WC=>WALL(IW)
   II  = WC%ONE_D%II
   JJ  = WC%ONE_D%JJ
   KK  = WC%ONE_D%KK
   IOR = WC%ONE_D%IOR

   ! Which face:
   X1AXIS=ABS(IOR)
   SELECT CASE(IOR)
   CASE( IAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK
   CASE(-IAXIS)
      IIF=II-1; JJF=JJ  ; KKF=KK
   CASE( JAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK
   CASE(-JAXIS)
      IIF=II  ; JJF=JJ-1; KKF=KK
   CASE( KAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK
   CASE(-KAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK-1
   END SELECT

   IF (WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY) THEN
      ! Drop if FACE is not type IBM_GASPHASE
      IF (FCVAR(IIF,JJF,KKF,IBM_FGSC,X1AXIS) /= IBM_GASPHASE) CYCLE GUARD_CUT_CELL_LOOP_1

      IIG  = WC%ONE_D%IIG
      JJG  = WC%ONE_D%JJG
      KKG  = WC%ONE_D%KKG

      ! Is this an actual RCFACE_VEL laying on the mesh boundary, where the cut-cell is in the guard-cell region?
      FLGIN = (CCVAR(II,JJ,KK,IBM_CGSC)==IBM_CUTCFE) .AND. (CCVAR(IIG,JJG,KKG,IBM_CGSC)==IBM_GASPHASE)

      IF(.NOT.FLGIN) CYCLE GUARD_CUT_CELL_LOOP_1

      IJKFACE(IIF,JJF,KKF,X1AXIS) = 1

   ELSE ! All other types of BCs (SOLID_BOUNDARY, NULL_BOUNDARY, OPEN_BOUNDARY) will not be added to RCFACES_H.

      IJKFACE(IIF,JJF,KKF,X1AXIS) = 0

   ENDIF

ENDDO GUARD_CUT_CELL_LOOP_1

IRC = SUM(IJKFACE(:,:,:,:))
IF (IRC == 0) THEN
   DEALLOCATE(IJKFACE)
   RETURN
ELSE
   ! Compute xc, yc, zc:
   ! Populate position and cell size arrays: Uniform grid implementation.
   ! X direction:
   ALLOCATE(XCELL(ISTR:IEND));  XCELL = 1._EB/GEOMEPS ! Initialize huge.
   XCELL(ILO_CELL-1:IHI_CELL+1) = MESHES(NM)%XC(ILO_CELL-1:IHI_CELL+1)

   ! Y direction:
   ALLOCATE(YCELL(JSTR:JEND));  YCELL = 1._EB/GEOMEPS ! Initialize huge.
   YCELL(JLO_CELL-1:JHI_CELL+1) = MESHES(NM)%YC(JLO_CELL-1:JHI_CELL+1)

   ! Z direction:
   ALLOCATE(ZCELL(KSTR:KEND));  ZCELL = 1._EB/GEOMEPS ! Initialize huge.
   ZCELL(KLO_CELL-1:KHI_CELL+1) = MESHES(NM)%ZC(KLO_CELL-1:KHI_CELL+1)
ENDIF

MESHES(NM)%IBM_NRCFACE_H = IRC ! Same number of regular - cut cell faces as scalars.
ALLOCATE( MESHES(NM)%IBM_RCFACE_H(IRC) )
IRC = 0
DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
   NCELL = CUT_CELL(ICC)%NCELL
   IJK(IAXIS:KAXIS) = CUT_CELL(ICC)%IJK(IAXIS:KAXIS)

   DO JCC=1,NCELL
      ! Loop faces and test:
      DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)

         IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)

         ! If face type in face_list is not IBM_FTYPE_RGGAS, drop:
         IF(CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_RGGAS) CYCLE

         ! Which face?
         LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
         X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)

         SELECT CASE(X1AXIS)
         CASE(IAXIS)
            X2AXIS = JAXIS
            X3AXIS = KAXIS
            ! location in I,J,K od x2,x2,x3 axes:
            XIAXIS = IAXIS; XJAXIS = JAXIS; XKAXIS = KAXIS
         CASE(JAXIS)
            X2AXIS = KAXIS
            X3AXIS = IAXIS
            ! location in I,J,K od x2,x2,x3 axes:
            XIAXIS = KAXIS; XJAXIS = IAXIS; XKAXIS = JAXIS
         CASE(KAXIS)
            X2AXIS = IAXIS
            X3AXIS = JAXIS
            ! location in I,J,K od x2,x2,x3 axes:
            XIAXIS = JAXIS; XJAXIS = KAXIS; XKAXIS = IAXIS
         END SELECT

         IF_LOW_HIGH_H : IF (LOWHIGH == LOW_IND) THEN

            ! Face indexes:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
            INFACE = INDXI1(XIAXIS)
            JNFACE = INDXI1(XJAXIS)
            KNFACE = INDXI1(XKAXIS)

            IF(IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS) /= 1) CYCLE ! This is to cycle external WALL CELLs of types other
                                                                ! than INTERPOLATED_BOUNDARY of PERIODIC_BOUNDARY.

            ! Location of next Cartesian cell:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
            INCELL = INDXI1(XIAXIS)
            JNCELL = INDXI1(XJAXIS)
            KNCELL = INDXI1(XKAXIS)

            IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured pressure Poisson matrix build,
                                               ! use cut-cell vols:
               IF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH) > 0 ) THEN

                  ! Add face to IBM_RCFACE_H data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. regular GASPHASE:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                      (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)

                  ! Cell at i+1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKH(JCC)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                      CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)

               ELSEIF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE ) THEN ! Cut-cell.

                  ! Test that Cut-cell to Cut-cell reg face hasn't been added before:
                  INLIST = .FALSE.
                  DO IIFC=1,IRC
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(IAXIS)   /= INFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(JAXIS)   /= JNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS)   /= KNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS+1) /= X1AXIS ) CYCLE
                     INLIST = .TRUE.
                     EXIT
                  ENDDO
                  IF (INLIST) THEN
                     ! Cell at i+1, i.e. cut-cell:
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKH(JCC)
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                           CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                     CYCLE
                  ENDIF

                  ! Add face to IBM_RCFACE_H data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i+1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKH(JCC)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                      CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)

               ENDIF

            ELSE ! Unstructured build, use underlying cartesian cells:

               IF (MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH) > 0 ) THEN ! Regular Gasphase

                  ! Add face to IBM_RCFACE_H data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. regular GASPHASE:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                      (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)

                  ! Cell at i+1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKH(1)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                      (/ XCELL(IJK(IAXIS)), YCELL(IJK(JAXIS)), ZCELL(IJK(KAXIS)) /)

               ELSEIF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE ) THEN ! Cut-cell.

                  ! Test that Cut-cell to Cut-cell reg face hasn't been added before:
                  INLIST = .FALSE.
                  DO IIFC=1,IRC
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(IAXIS)   /= INFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(JAXIS)   /= JNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS)   /= KNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS+1) /= X1AXIS ) CYCLE
                     INLIST = .TRUE.
                     EXIT
                  ENDDO
                  IF (INLIST) THEN
                     ! Cell at i+1, i.e. cut-cell:
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKH(1)
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                     (/ XCELL(IJK(IAXIS)), YCELL(IJK(JAXIS)), ZCELL(IJK(KAXIS)) /)
                     CYCLE
                  ENDIF

                  ! Add face to IBM_RCFACE_H data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i+1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKH(1)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                      (/ XCELL(IJK(IAXIS)), YCELL(IJK(JAXIS)), ZCELL(IJK(KAXIS)) /)

               ENDIF
            ENDIF

         ELSE ! IF_LOW_HIGH_H : HIGH_IND

            ! Face indexes:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS), IJK(X2AXIS), IJK(X3AXIS) /)
            INFACE = INDXI1(XIAXIS)
            JNFACE = INDXI1(XJAXIS)
            KNFACE = INDXI1(XKAXIS)

            IF(IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS) /= 1) CYCLE ! This is to cycle external WALL CELLs of types other
                                                                ! than INTERPOLATED_BOUNDARY of PERIODIC_BOUNDARY.

            ! Location of next Cartesian cell:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)+1, IJK(X2AXIS), IJK(X3AXIS) /)
            INCELL = INDXI1(XIAXIS)
            JNCELL = INDXI1(XJAXIS)
            KNCELL = INDXI1(XKAXIS)

            IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured pressure Poisson matrix build,
                                               ! use cut-cell vols:

               IF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH) > 0 ) THEN

                  ! Add face to IBM_RCFACE_H data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKH(JCC)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                      CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)

                  ! Cell at i+1, i.e. regular GASPHASE:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = &
                  MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                      (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)

               ELSEIF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE ) THEN ! Cut-cell.

                  ! Test that Cut-cell to Cut-cell reg face hasn't been added before:
                  INLIST = .FALSE.
                  DO IIFC=1,IRC
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(IAXIS)   /= INFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(JAXIS)   /= JNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS)   /= KNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS+1) /= X1AXIS ) CYCLE
                     INLIST = .TRUE.
                     EXIT
                  ENDDO
                  IF (INLIST) THEN
                     ! Cell at i-1, i.e. cut-cell:
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKH(JCC)
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                     CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                     CYCLE
                  ENDIF

                  ! Add face to REGC_FACE_H  data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKH(JCC)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                      CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)

               ENDIF

            ELSE ! Unstructured build, use underlying cartesian cells:

               IF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH) > 0 ) THEN ! Regular Gasphase

                  ! Add face to REGC_FACE_H  data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKH(1)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                      (/ XCELL(IJK(IAXIS)), YCELL(IJK(JAXIS)), ZCELL(IJK(KAXIS)) /)

                  ! Cell at i+1, i.e. regular GASPHASE:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = &
                  MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKH)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                      (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)

               ELSEIF ( MESHES(NM)%CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE ) THEN ! Cut-cell.

                  ! Test that Cut-cell to Cut-cell reg face hasn't been added before:
                  INLIST = .FALSE.
                  DO IIFC=1,IRC
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(IAXIS)   /= INFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(JAXIS)   /= JNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS)   /= KNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_H(IIFC)%IJK(KAXIS+1) /= X1AXIS ) CYCLE
                     INLIST = .TRUE.
                     EXIT
                  ENDDO
                  IF (INLIST) THEN
                     ! Cell at i-1, i.e. cut-cell:
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKH(1)
                     MESHES(NM)%IBM_RCFACE_H(IIFC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                     (/ XCELL(IJK(IAXIS)), YCELL(IJK(JAXIS)), ZCELL(IJK(KAXIS)) /)
                     CYCLE
                  ENDIF

                  ! Add face to REGC_FACE_H  data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKH(1)
                  MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                      (/ XCELL(IJK(IAXIS)), YCELL(IJK(JAXIS)), ZCELL(IJK(KAXIS)) /)

               ENDIF
            ENDIF ! .NOT.PRES_ON_CARTESIAN

         ENDIF IF_LOW_HIGH_H

      ENDDO
   ENDDO
ENDDO

GUARD_CUT_CELL_LOOP_2 :  DO IW=1,N_EXTERNAL_WALL_CELLS
   WC=>WALL(IW)
   IF (.NOT.(WC%BOUNDARY_TYPE==INTERPOLATED_BOUNDARY .OR. WC%BOUNDARY_TYPE==PERIODIC_BOUNDARY)) &
   CYCLE GUARD_CUT_CELL_LOOP_2

   II  = WC%ONE_D%II
   JJ  = WC%ONE_D%JJ
   KK  = WC%ONE_D%KK
   IOR = WC%ONE_D%IOR

   ! Which face:
   X1AXIS=ABS(IOR)
   SELECT CASE(IOR)
   CASE( IAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK
      LOWHIGH_TEST=HIGH_IND ! Face on high side of Guard-Cell
   CASE(-IAXIS)
      IIF=II-1; JJF=JJ  ; KKF=KK
      LOWHIGH_TEST=LOW_IND
   CASE( JAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK
      LOWHIGH_TEST=HIGH_IND
   CASE(-JAXIS)
      IIF=II  ; JJF=JJ-1; KKF=KK
      LOWHIGH_TEST=LOW_IND
   CASE( KAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK
      LOWHIGH_TEST=HIGH_IND
   CASE(-KAXIS)
      IIF=II  ; JJF=JJ  ; KKF=KK-1
      LOWHIGH_TEST=LOW_IND
   END SELECT

   ! Drop if FACE is not type IBM_GASPHASE
   IF (FCVAR(IIF,JJF,KKF,IBM_FGSC,X1AXIS) /= IBM_GASPHASE) CYCLE GUARD_CUT_CELL_LOOP_2

   IIG  = WC%ONE_D%IIG
   JJG  = WC%ONE_D%JJG
   KKG  = WC%ONE_D%KKG

   ! Is this an actual RCFACE_H laying on the mesh boundary, where the cut-cell is in the guard-cell region?
   FLGIN = (CCVAR(II,JJ,KK,IBM_CGSC)==IBM_CUTCFE) .AND. (CCVAR(IIG,JJG,KKG,IBM_UNKH) > 0)

   IF(.NOT.FLGIN) CYCLE GUARD_CUT_CELL_LOOP_2

   ICC=CCVAR(II,JJ,KK,IBM_IDCC)
   DO JCC=1,CUT_CELL(ICC)%NCELL
      ! Loop faces and test:
      DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
         IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
         ! Which face ?
         LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
         IF ( CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_RGGAS) CYCLE ! Must Be gasphase cut-face
         IF ( LOWHIGH                              /= LOWHIGH_TEST) CYCLE ! In same side as EWC from guard-cell
         IF ( CUT_CELL(ICC)%FACE_LIST(3,IFACE) /= X1AXIS) CYCLE ! Normal to same axis as EWC

          ! If so, we need to add it to the IBM_RCFACE_H list:
         IF (LOWHIGH == LOW_IND) THEN ! Face on low side of guard cut-cell

            IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured pressure Poisson matrix build,
                                               ! use cut-cell vols:
               ! Work deferred.

            ELSE ! Solve Poisson on underlying unstructured Cartesian mesh.

               ! Add face to IBM_RCFACE_H data structure:
               IRC = IRC + 1
               MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ IIF, JJF, KKF, X1AXIS/)

               ! Add all info required for matrix build:
               ! Cell at i-1, i.e. regular GASPHASE:
               MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = CCVAR(IIG,JJG,KKG,IBM_UNKH)
               MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
               (/ XCELL(IIG), YCELL(JJG), ZCELL(KKG) /)

               ! Cell at i+1, i.e. cut-cell:
               MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKH(1)
               MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
               (/ XCELL(II), YCELL(JJ), ZCELL(KK) /)

            ENDIF

         ELSEIF(LOWHIGH == HIGH_IND) THEN ! Face on high side of guard cut-cell

            IF ( .NOT.PRES_ON_CARTESIAN ) THEN ! Unstructured pressure Poisson matrix build,
                                               ! use cut-cell vols:
               ! Work deferred.

            ELSE ! Solve Poisson on underlying unstructured Cartesian mesh.

               ! Add face to IBM_RCFACE_H data structure:
               IRC = IRC + 1
               MESHES(NM)%IBM_RCFACE_H(IRC)%IJK(IAXIS:KAXIS+1) = (/ IIF, JJF, KKF, X1AXIS/)

               ! Add all info required for matrix build:
               ! Cell at i-1, i.e. cut-cell:
               MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKH(1)
               MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
               (/ XCELL(II), YCELL(JJ), ZCELL(KK) /)

               ! Cell at i+1, i.e. regular GASPHASE:
               MESHES(NM)%IBM_RCFACE_H(IRC)%UNK(HIGH_IND) = CCVAR(IIG,JJG,KKG,IBM_UNKH)
               MESHES(NM)%IBM_RCFACE_H(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
               (/ XCELL(IIG), YCELL(JJG), ZCELL(KKG) /)
            ENDIF

         ENDIF
         ! At this point the face has been found, cycle:
         CYCLE GUARD_CUT_CELL_LOOP_2
      ENDDO
   ENDDO

ENDDO GUARD_CUT_CELL_LOOP_2

DEALLOCATE(XCELL,YCELL,ZCELL)
DEALLOCATE(IJKFACE)

RETURN
END SUBROUTINE GET_RCFACES_H


! ---------------------- GET_GASPHASE_REGFACES_DATA -----------------------------

SUBROUTINE GET_GASPHASE_REGFACES_DATA

USE MPI_F08

! Local variables:
INTEGER :: NM
INTEGER :: ILO,IHI,JLO,JHI,KLO,KHI
INTEGER :: I,J,K,II,IREG,IRC,IIFC,X1AXIS,X2AXIS,X3AXIS
INTEGER, ALLOCATABLE, DIMENSION(:,:) :: IJKBUFFER
LOGICAL, ALLOCATABLE, DIMENSION(:,:) :: LOHIBUFF
INTEGER, ALLOCATABLE, DIMENSION(:,:,:,:,:) :: IJKFACE
INTEGER :: NCELL,ICC,JCC,IJK(MAX_DIM),IFC,IFACE,LOWHIGH
INTEGER :: XIAXIS,XJAXIS,XKAXIS,INDXI1(MAX_DIM),INCELL,JNCELL,KNCELL,INFACE,JNFACE,KNFACE
INTEGER :: ISTR, IEND, JSTR, JEND, KSTR, KEND
LOGICAL :: INLIST

INTEGER :: IW,JJ,KK,IIF,JJF,KKF,IOR,LOWHIGH_TEST,IIG,JJG,KKG
INTEGER :: IBNDINT,IC
TYPE (WALL_TYPE), POINTER :: WC
LOGICAL :: FLGIN
INTEGER, PARAMETER :: OZPOS=0, ICPOS=1, JCPOS=2, IFPOS=3
INTEGER :: IERR

! Mesh loop:
MAIN_MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! Mesh sizes:
   NXB=IBAR
   NYB=JBAR
   NZB=KBAR

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.
   ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
   IHI_CELL = IHI_FACE ! Last internal cell index.
   ISTR     = ILO_FACE - NGUARD    ! Allocation start x arrays.
   IEND     = IHI_FACE + NGUARD    ! Allocation end x arrays.


   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.
   JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
   JHI_CELL = JHI_FACE ! Last internal cell index.
   JSTR     = JLO_FACE - NGUARD    ! Allocation start y arrays.
   JEND     = JHI_FACE + NGUARD    ! Allocation end y arrays.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.
   KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
   KHI_CELL = KHI_FACE ! Last internal cell index.
   KSTR     = KLO_FACE - NGUARD    ! Allocation start z arrays.
   KEND     = KHI_FACE + NGUARD    ! Allocation end z arrays.

   ! Define grid arrays for this mesh:
   ! Populate position and cell size arrays: Uniform grid implementation.
   ! X direction:
   ALLOCATE(XCELL(ISTR:IEND));  XCELL = 1._EB/GEOMEPS ! Initialize huge.
   XCELL(ILO_CELL-1:IHI_CELL+1) = MESHES(NM)%XC(ILO_CELL-1:IHI_CELL+1)

   ! Y direction:
   ALLOCATE(YCELL(JSTR:JEND));  YCELL = 1._EB/GEOMEPS ! Initialize huge.
   YCELL(JLO_CELL-1:JHI_CELL+1) = MESHES(NM)%YC(JLO_CELL-1:JHI_CELL+1)

   ! Z direction:
   ALLOCATE(ZCELL(KSTR:KEND));  ZCELL = 1._EB/GEOMEPS ! Initialize huge.
   ZCELL(KLO_CELL-1:KHI_CELL+1) = MESHES(NM)%ZC(KLO_CELL-1:KHI_CELL+1)

   ! Set starting number of regular faces for NM to zero:
   MESHES(NM)%IBM_NREGFACE_Z(IAXIS:KAXIS) = 0

   ! 1. Regular GASPHASE faces connected to Gasphase cells:
   ALLOCATE(IJKBUFFER(IAXIS:KAXIS+1,1:(NXB+1)*(NYB+1)*(NZB+1)))
   ALLOCATE(LOHIBUFF(LOW_IND:HIGH_IND,1:(NXB+1)*(NYB+1)*(NZB+1)))

   ! First Scalars:
   ! axis = IAXIS:
   X1AXIS = IAXIS
   IJKBUFFER(:,:)=0; LOHIBUFF(:,:)=.FALSE.; IREG = 0
   ! First Reg Faces in mesh block boundaries, then inside mesh. Count for allocation:
   IBNDINT_LOOP_X : DO IBNDINT=1,3
      IF(IBNDINT==3) MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)=IREG ! REG faces in block boundaries.
      SELECT CASE(IBNDINT)
      CASE(1)
         ILO = ILO_FACE; IHI = ILO_FACE
         JLO = JLO_CELL; JHI = JHI_CELL
         KLO = KLO_CELL; KHI = KHI_CELL
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I  ,J,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I+1,J,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I+1,J,K,IBM_UNKZ)<=0 ) CYCLE ! Either face out of CCREGION or EXIM face with CCREGION outside of mesh.
                  IREG = IREG + 1
                  IF ( CCVAR(I  ,J,K,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I+1,J,K,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC   = CELL_INDEX(I+1  ,J,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC,-X1AXIS) /) ! Face on low side of cell.
               ENDDO
            ENDDO
         ENDDO
      CASE(2)
         ILO = IHI_FACE; IHI = IHI_FACE
         JLO = JLO_CELL; JHI = JHI_CELL
         KLO = KLO_CELL; KHI = KHI_CELL
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I  ,J,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I+1,J,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I  ,J,K,IBM_UNKZ)<=0 ) CYCLE ! Either face out of CCREGION or EXIM face with CCREGION outside of mesh.
                  IREG = IREG + 1
                  IF ( CCVAR(I  ,J,K,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I+1,J,K,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC = CELL_INDEX(I,J,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC, X1AXIS) /) ! Face on high side of cell.
               ENDDO
            ENDDO
         ENDDO
      CASE(3)
         ILO = ILO_FACE+1; IHI = IHI_FACE-1
         JLO = JLO_CELL;   JHI = JHI_CELL
         KLO = KLO_CELL;   KHI = KHI_CELL
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I  ,J,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I+1,J,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( (CCVAR(I,J,K,IBM_UNKZ)<=0) .AND. (CCVAR(I+1,J,K,IBM_UNKZ)<=0) ) CYCLE
                  IREG = IREG + 1
                  IF ( CCVAR(I  ,J,K,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I+1,J,K,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC = CELL_INDEX(I,J,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC, X1AXIS) /)
               ENDDO
            ENDDO
         ENDDO
      END SELECT
   ENDDO IBNDINT_LOOP_X
   MESHES(NM)%IBM_NREGFACE_Z(X1AXIS) = IREG
   IF(ALLOCATED(MESHES(NM)%IBM_REGFACE_IAXIS_Z)) DEALLOCATE(MESHES(NM)%IBM_REGFACE_IAXIS_Z)
   ALLOCATE(MESHES(NM)%IBM_REGFACE_IAXIS_Z(IREG))
   DO II=1,IREG
      MESHES(NM)%IBM_REGFACE_IAXIS_Z(II)%IJK(IAXIS:KAXIS) = IJKBUFFER(IAXIS:KAXIS,II)
      MESHES(NM)%IBM_REGFACE_IAXIS_Z(II)%IWC              = IJKBUFFER(KAXIS+1,II)
      MESHES(NM)%IBM_REGFACE_IAXIS_Z(II)%DO_LO_IND        = LOHIBUFF(LOW_IND,II)
      MESHES(NM)%IBM_REGFACE_IAXIS_Z(II)%DO_HI_IND        = LOHIBUFF(HIGH_IND,II)
   ENDDO

   ! axis = JAXIS:
   X1AXIS = JAXIS
   IJKBUFFER(:,:)=0; LOHIBUFF(:,:)=.FALSE.; IREG = 0
   ! First Reg Faces in mesh block boundaries, then inside mesh. Count for allocation:
   IBNDINT_LOOP_Y : DO IBNDINT=1,3
      IF(IBNDINT==3) MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)=IREG ! REG faces in block boundaries.
      SELECT CASE(IBNDINT)
      CASE(1)
         ILO = ILO_CELL; IHI = IHI_CELL
         JLO = JLO_FACE; JHI = JLO_FACE
         KLO = KLO_CELL; KHI = KHI_CELL
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I,J  ,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J+1,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J+1,K,IBM_UNKZ)<=0 ) CYCLE ! Either face out of CCREGION or EXIM face with CCREGION outside of mesh.
                  IREG = IREG + 1
                  IF ( CCVAR(I,J  ,K,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I,J+1,K,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC   = CELL_INDEX(I,J+1  ,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC,-X1AXIS) /) ! Face on low side of cell.
               ENDDO
            ENDDO
         ENDDO
      CASE(2)
         ILO = ILO_CELL; IHI = IHI_CELL
         JLO = JHI_FACE; JHI = JHI_FACE
         KLO = KLO_CELL; KHI = KHI_CELL
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I,J  ,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J+1,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J  ,K,IBM_UNKZ)<=0 ) CYCLE ! Either face out of CCREGION or EXIM face with CCREGION outside of mesh.
                  IREG = IREG + 1
                  IF ( CCVAR(I,J  ,K,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I,J+1,K,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC   = CELL_INDEX(I,J,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC, X1AXIS) /) ! Face on high side of cell.
               ENDDO
            ENDDO
         ENDDO
      CASE(3)
         ILO = ILO_CELL;   IHI = IHI_CELL
         JLO = JLO_FACE+1; JHI = JHI_FACE-1
         KLO = KLO_CELL;   KHI = KHI_CELL
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I,J  ,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J+1,K,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( (CCVAR(I,J,K,IBM_UNKZ)<=0) .AND. (CCVAR(I,J+1,K,IBM_UNKZ)<=0) ) CYCLE
                  IREG = IREG + 1
                  IF ( CCVAR(I,J  ,K,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I,J+1,K,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC   = CELL_INDEX(I,J,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC, X1AXIS) /)
               ENDDO
            ENDDO
         ENDDO
      END SELECT
   ENDDO IBNDINT_LOOP_Y
   MESHES(NM)%IBM_NREGFACE_Z(X1AXIS) = IREG
   IF(ALLOCATED(MESHES(NM)%IBM_REGFACE_JAXIS_Z)) DEALLOCATE(MESHES(NM)%IBM_REGFACE_JAXIS_Z)
   ALLOCATE(MESHES(NM)%IBM_REGFACE_JAXIS_Z(IREG))
   DO II=1,IREG
      MESHES(NM)%IBM_REGFACE_JAXIS_Z(II)%IJK(IAXIS:KAXIS) = IJKBUFFER(IAXIS:KAXIS,II)
      MESHES(NM)%IBM_REGFACE_JAXIS_Z(II)%IWC              = IJKBUFFER(KAXIS+1,II)
      MESHES(NM)%IBM_REGFACE_JAXIS_Z(II)%DO_LO_IND        = LOHIBUFF(LOW_IND,II)
      MESHES(NM)%IBM_REGFACE_JAXIS_Z(II)%DO_HI_IND        = LOHIBUFF(HIGH_IND,II)
   ENDDO

   ! axis = KAXIS:
   X1AXIS = KAXIS
   IJKBUFFER(:,:)=0; LOHIBUFF(:,:)=.FALSE.; IREG = 0
   ! First Reg Faces in mesh block boundaries, then inside mesh.
   IBNDINT_LOOP_Z : DO IBNDINT=1,3
      IF(IBNDINT==3) MESHES(NM)%IBM_NBBREGFACE_Z(X1AXIS)=IREG ! REG faces in block boundaries.
      SELECT CASE(IBNDINT)
      CASE(1)
         ILO = ILO_CELL; IHI = IHI_CELL
         JLO = JLO_CELL; JHI = JHI_CELL
         KLO = KLO_FACE; KHI = KLO_FACE
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I,J,K  ,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J,K+1,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J,K+1,IBM_UNKZ)<=0 ) CYCLE ! Either face out of CCREGION or EXIM face with CCREGION outside of mesh.
                  IREG = IREG + 1
                  IF ( CCVAR(I,J,K  ,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I,J,K+1,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC   = CELL_INDEX(I,J,K+1 )
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC,-X1AXIS) /)  ! Face on low side of cell.
               ENDDO
            ENDDO
         ENDDO
      CASE(2)
         ILO = ILO_CELL; IHI = IHI_CELL
         JLO = JLO_CELL; JHI = JHI_CELL
         KLO = KHI_FACE; KHI = KHI_FACE
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I,J,K  ,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J,K+1,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J,K  ,IBM_UNKZ)<=0 ) CYCLE ! Either face out of CCREGION or EXIM face with CCREGION outside of mesh.
                  IREG = IREG + 1
                  IF ( CCVAR(I,J,K  ,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I,J,K+1,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC   = CELL_INDEX(I,J,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC, X1AXIS) /)  ! Face on high side of cell.
               ENDDO
            ENDDO
         ENDDO
      CASE(3)
         ILO = ILO_CELL;   IHI = IHI_CELL
         JLO = JLO_CELL;   JHI = JHI_CELL
         KLO = KLO_FACE+1; KHI = KHI_FACE-1
         DO K=KLO,KHI
            DO J=JLO,JHI
               DO I=ILO,IHI
                  IF ( CCVAR(I,J,K  ,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( CCVAR(I,J,K+1,IBM_CGSC) /= IBM_GASPHASE ) CYCLE
                  IF ( (CCVAR(I,J,K,IBM_UNKZ)<=0) .AND. (CCVAR(I,J,K+1,IBM_UNKZ)<=0) ) CYCLE
                  IREG = IREG + 1
                  IF ( CCVAR(I,J,K  ,IBM_UNKZ)>0 ) LOHIBUFF(LOW_IND,IREG) = .TRUE.
                  IF ( CCVAR(I,J,K+1,IBM_UNKZ)>0 ) LOHIBUFF(HIGH_IND,IREG)= .TRUE.
                  IC   = CELL_INDEX(I,J,K)
                  IJKBUFFER(IAXIS:KAXIS+1,IREG) = (/ I, J, K, WALL_INDEX(IC, X1AXIS) /)
               ENDDO
            ENDDO
         ENDDO
      END SELECT
   ENDDO IBNDINT_LOOP_Z
   MESHES(NM)%IBM_NREGFACE_Z(X1AXIS) = IREG
   IF(ALLOCATED(MESHES(NM)%IBM_REGFACE_KAXIS_Z)) DEALLOCATE(MESHES(NM)%IBM_REGFACE_KAXIS_Z)
   ALLOCATE(MESHES(NM)%IBM_REGFACE_KAXIS_Z(IREG))
   DO II=1,IREG
      MESHES(NM)%IBM_REGFACE_KAXIS_Z(II)%IJK(IAXIS:KAXIS) = IJKBUFFER(IAXIS:KAXIS,II)
      MESHES(NM)%IBM_REGFACE_KAXIS_Z(II)%IWC              = IJKBUFFER(KAXIS+1,II)
      MESHES(NM)%IBM_REGFACE_KAXIS_Z(II)%DO_LO_IND        = LOHIBUFF(LOW_IND,II)
      MESHES(NM)%IBM_REGFACE_KAXIS_Z(II)%DO_HI_IND        = LOHIBUFF(HIGH_IND,II)
   ENDDO

   ! 2. Lists of Regular Gasphase faces, connected to one regular gasphase and one cut-cell:
   ! First count for allocation:
   ALLOCATE( IJKFACE(ILO_FACE:IHI_FACE,JLO_FACE:JHI_FACE,KLO_FACE:KHI_FACE,IAXIS:KAXIS,OZPOS:IFPOS) )
   IJKFACE(:,:,:,:,:) = 0
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      NCELL = CUT_CELL(ICC)%NCELL
      IJK(IAXIS:KAXIS) = CUT_CELL(ICC)%IJK(IAXIS:KAXIS)
      DO JCC=1,NCELL
         ! Loop faces and test:
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! If face type in face_list is not IBM_FTYPE_RGGAS, drop:
            IF(CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_RGGAS) CYCLE
            ! Which face?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)
            SELECT CASE(X1AXIS)
            CASE(IAXIS)
               X2AXIS = JAXIS; X3AXIS = KAXIS
               ! location in I,J,K od x2,x2,x3 axes:
               XIAXIS = IAXIS; XJAXIS = JAXIS; XKAXIS = KAXIS
            CASE(JAXIS)
               X2AXIS = KAXIS; X3AXIS = IAXIS
               ! location in I,J,K od x2,x2,x3 axes:
               XIAXIS = KAXIS; XJAXIS = IAXIS; XKAXIS = JAXIS
            CASE(KAXIS)
               X2AXIS = IAXIS; X3AXIS = JAXIS
               ! location in I,J,K od x2,x2,x3 axes:
               XIAXIS = JAXIS; XJAXIS = KAXIS; XKAXIS = IAXIS
            END SELECT

            ! Face indexes:
            INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1+(LOWHIGH-1), IJK(X2AXIS), IJK(X3AXIS) /)
            INFACE = INDXI1(XIAXIS)
            JNFACE = INDXI1(XJAXIS)
            KNFACE = INDXI1(XKAXIS)

            IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS,OZPOS) = 1
            IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS,ICPOS) = ICC
            IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS,JCPOS) = JCC
            IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS,IFPOS) = IFACE

         ENDDO
      ENDDO
   ENDDO

   ! Check for RCFACE_Z on the boundary of the domain, where the cut-cell is in the guard-cell region.
   ! Now Apply external wall cell loop for guard-cell cut cells:
   GUARD_CUT_CELL_LOOP_1A :  DO IW=1,N_EXTERNAL_WALL_CELLS
      WC=>WALL(IW)

      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK
      IOR = WC%ONE_D%IOR

      ! Which face:
      X1AXIS=ABS(IOR)
      SELECT CASE(IOR)
      CASE( IAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND ! Face on high side of Guard-Cell
      CASE(-IAXIS)
         IIF=II-1; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=LOW_IND
      CASE( JAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND
      CASE(-JAXIS)
         IIF=II  ; JJF=JJ-1; KKF=KK
         LOWHIGH_TEST=LOW_IND
      CASE( KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND
      CASE(-KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK-1
         LOWHIGH_TEST=LOW_IND
      END SELECT

      ! Drop if FACE is not type IBM_GASPHASE
      IF (FCVAR(IIF,JJF,KKF,IBM_FGSC,X1AXIS) /= IBM_GASPHASE) CYCLE GUARD_CUT_CELL_LOOP_1A

      IIG  = WC%ONE_D%IIG
      JJG  = WC%ONE_D%JJG
      KKG  = WC%ONE_D%KKG

      ! Is this an actual RCFACE laying on the mesh boundary, where the cut-cell is in the guard-cell region?
      FLGIN = (CCVAR(II,JJ,KK,IBM_CGSC)==IBM_CUTCFE) ! Note that this will overrride the Cut-cell to cut-cell case in
                                                     ! the block boundary, picked up in previous loop. Thats fine.

      IF(.NOT.FLGIN) CYCLE GUARD_CUT_CELL_LOOP_1A

      ICC=CCVAR(II,JJ,KK,IBM_IDCC)
      DO JCC=1,CUT_CELL(ICC)%NCELL
         ! Loop faces and test:
         DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
            ! Which face ?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            IF ( CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_RGGAS) CYCLE ! Must Be gasphase cut-face
            IF ( LOWHIGH                             /= LOWHIGH_TEST) CYCLE ! In same side as EWC from guard-cell
            IF ( CUT_CELL(ICC)%FACE_LIST(3,IFACE) /= X1AXIS) CYCLE ! Normal to same axis as EWC

            IJKFACE(IIF,JJF,KKF,X1AXIS,OZPOS) = 1
            IJKFACE(IIF,JJF,KKF,X1AXIS,ICPOS) = ICC
            IJKFACE(IIF,JJF,KKF,X1AXIS,JCPOS) = JCC
            IJKFACE(IIF,JJF,KKF,X1AXIS,IFPOS) = IFACE

            CYCLE GUARD_CUT_CELL_LOOP_1A
         ENDDO
      ENDDO

   ENDDO GUARD_CUT_CELL_LOOP_1A

   IRC = SUM(IJKFACE(:,:,:,:,OZPOS))
   IF (IRC == 0) THEN
      DEALLOCATE(XCELL,YCELL,ZCELL)
      DEALLOCATE(IJKBUFFER,LOHIBUFF,IJKFACE)
      CYCLE
   ENDIF

   ! Now actual computation for Scalars:
   ALLOCATE( MESHES(NM)%IBM_RCFACE_Z(IRC) )
   IRC = 0
   ! Start with external wall cells:
   GUARD_CUT_CELL_LOOP_1B :  DO IW=1,N_EXTERNAL_WALL_CELLS
      WC=>WALL(IW)
      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK
      IOR = WC%ONE_D%IOR

      ! Which face:
      X1AXIS=ABS(IOR)
      SELECT CASE(IOR)
      CASE( IAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND ! Face on high side of Guard-Cell
      CASE(-IAXIS)
         IIF=II-1; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=LOW_IND
      CASE( JAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND
      CASE(-JAXIS)
         IIF=II  ; JJF=JJ-1; KKF=KK
         LOWHIGH_TEST=LOW_IND
      CASE( KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK
         LOWHIGH_TEST=HIGH_IND
      CASE(-KAXIS)
         IIF=II  ; JJF=JJ  ; KKF=KK-1
         LOWHIGH_TEST=LOW_IND
      END SELECT

      IF(IJKFACE(IIF,JJF,KKF,X1AXIS,OZPOS) < 1) CYCLE GUARD_CUT_CELL_LOOP_1B ! Not an RCFACE_Z.

      ! None of the following defined RCFACES in block boundaries have been added to IBM_RCFACE_Z before:
      ICC = IJKFACE(IIF,JJF,KKF,X1AXIS,ICPOS)
      JCC = IJKFACE(IIF,JJF,KKF,X1AXIS,JCPOS)
      IFACE = IJKFACE(IIF,JJF,KKF,X1AXIS,IFPOS)
      IJK(IAXIS:KAXIS) = CUT_CELL(ICC)%IJK(IAXIS:KAXIS)
      ! Which face?
      LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)

      ! Add face to RC face:
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         X2AXIS = JAXIS
         X3AXIS = KAXIS
         ! location in I,J,K od x2,x2,x3 axes:
         XIAXIS = IAXIS; XJAXIS = JAXIS; XKAXIS = KAXIS
      CASE(JAXIS)
         X2AXIS = KAXIS
         X3AXIS = IAXIS
         ! location in I,J,K od x2,x2,x3 axes:
         XIAXIS = KAXIS; XJAXIS = IAXIS; XKAXIS = JAXIS
      CASE(KAXIS)
         X2AXIS = IAXIS
         X3AXIS = JAXIS
         ! location in I,J,K od x2,x2,x3 axes:
         XIAXIS = JAXIS; XJAXIS = KAXIS; XKAXIS = IAXIS
      END SELECT

      IF_LOW_HIGH_1B : IF (LOWHIGH == LOW_IND) THEN

         ! Face indexes:
         INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
         INFACE = INDXI1(XIAXIS)
         JNFACE = INDXI1(XJAXIS)
         KNFACE = INDXI1(XKAXIS)

         ! Location of next Cartesian cell:
         INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
         INCELL = INDXI1(XIAXIS)
         JNCELL = INDXI1(XJAXIS)
         KNCELL = INDXI1(XKAXIS)

         ! Scalar:
         IF (CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_GASPHASE ) THEN ! next cell is reg-cell:

            ! Set OZPOS to 2, to be used in next cycle:
            IJKFACE(IIF,JJF,KKF,X1AXIS,OZPOS) = 2
            ! Add face to IBM_RCFACE_Z data structure:
            IRC = IRC + 1
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IWC = IW ! Locate WALL CELL for boundary MESHES(NM)%IBM_RCFACE_Z(IRC).

            ! Can compute Area and centroid location of reg
            ! face when building matrix.

            ! Add all info required for matrix build:
            ! Cell at i-1, i.e. regular GASPHASE:
            MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(LOW_IND) = CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKZ)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
            (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND) = &
            (/ IBM_FTYPE_RGGAS, INCELL, JNCELL, KNCELL /)

            ! Cell at i+1, i.e. cut-cell:
            MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKZ(JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
            CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND) = &
            (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)

            ! Modify FACE_LIST for the given cut-cell:
            CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC
         ELSEIF(CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE) THEN ! next cell is cc:

            ! Set OZPOS to 2, to be used in next cycle:
            IJKFACE(IIF,JJF,KKF,X1AXIS,OZPOS) = 2
            ! Add face to IBM_RCFACE_Z  data structure:
            IRC = IRC + 1
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IWC = IW ! Locate WALL CELL for boundary MESHES(NM)%IBM_RCFACE_Z(IRC).

            ! Can compute Area and centroid location of reg
            ! face when building matrix.

            ! Add all info required for matrix build:
            ! Cell at i+1, i.e. cut-cell:
            MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKZ(JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
            CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND) = &
            (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)

            ! Modify FACE_LIST for the given cut-cell:
            CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC
         ELSE
            WRITE(LU_ERR,*) 'MISSING BOUNDARY RCFACE',IIF,JJF,KKF,X1AXIS
         ENDIF

      ELSE ! IF_LOW_HIGH : HIGH_IND

         ! Face indexes:
         INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS), IJK(X2AXIS), IJK(X3AXIS) /)
         INFACE = INDXI1(XIAXIS)
         JNFACE = INDXI1(XJAXIS)
         KNFACE = INDXI1(XKAXIS)

         ! Location of next Cartesian cell:
         INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)+1, IJK(X2AXIS), IJK(X3AXIS) /)
         INCELL = INDXI1(XIAXIS)
         JNCELL = INDXI1(XJAXIS)
         KNCELL = INDXI1(XKAXIS)

         IF (CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_GASPHASE ) THEN

            ! Set OZPOS to 2, to be used in next cycle:
            IJKFACE(IIF,JJF,KKF,X1AXIS,OZPOS) = 2
            ! Add face to IBM_RCFACE_Z data structure:
            IRC = IRC + 1
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IWC = IW ! Locate WALL CELL for boundary MESHES(NM)%IBM_RCFACE_Z(IRC).

            ! Can compute Area and centroid location of reg
            ! face when building matrix.

            ! Add all info required for matrix build:
            ! Cell at i-1, i.e. cut-cell:
            MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKZ(JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                 CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND) = &
            (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)
            ! Modify FACE_LIST for the given cut-cell:
            CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC

            ! Cell at i+1, i.e. regular GASPHASE:
            MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(HIGH_IND) = CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKZ)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                       (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND) = &
            (/ IBM_FTYPE_RGGAS, INCELL, JNCELL, KNCELL /)

         ELSEIF(CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE) THEN ! next cell is cc:

            ! Set OZPOS to 2, to be used in next cycle:
            IJKFACE(IIF,JJF,KKF,X1AXIS,OZPOS) = 2
            ! Add face to IBM_RCFACE_Z data structure:
            IRC = IRC + 1
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%IWC = IW ! Locate WALL CELL for boundary MESHES(NM)%IBM_RCFACE_Z(IRC).

            ! Can compute Area and centroid location of reg
            ! face when building matrix.

            ! Add high cell info required for matrix build:
            ! Cell at i-1, i.e. cut-cell:
            MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKZ(JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
            MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND) = &
            (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)

            ! Modify FACE_LIST for the given cut-cell:
            CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC
           ELSE
              WRITE(LU_ERR,*) 'MISSING BOUNDARY RCFACE',IIF,JJF,KKF,X1AXIS
         ENDIF
      ENDIF IF_LOW_HIGH_1B

   ENDDO GUARD_CUT_CELL_LOOP_1B

   ! Number of RC faces defined in block boundaries:
   MESHES(NM)%IBM_NBBRCFACE_Z = IRC

   ! Now run regular cut-cell loop to define internal RCFACES:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      NCELL = CUT_CELL(ICC)%NCELL
      IJK(IAXIS:KAXIS) = CUT_CELL(ICC)%IJK(IAXIS:KAXIS)

      DO JCC=1,NCELL
         ! Loop faces and test:
         IFC_LOOP : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)

            IFACE = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)

            ! If face type in face_list is not IBM_FTYPE_RGGAS, drop:
            IF(CUT_CELL(ICC)%FACE_LIST(1,IFACE) /= IBM_FTYPE_RGGAS) CYCLE IFC_LOOP

            ! Which face?
            LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
            X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)

            SELECT CASE(X1AXIS)
            CASE(IAXIS)
               X2AXIS = JAXIS
               X3AXIS = KAXIS
               ! location in I,J,K od x2,x2,x3 axes:
               XIAXIS = IAXIS; XJAXIS = JAXIS; XKAXIS = KAXIS
            CASE(JAXIS)
               X2AXIS = KAXIS
               X3AXIS = IAXIS
               ! location in I,J,K od x2,x2,x3 axes:
               XIAXIS = KAXIS; XJAXIS = IAXIS; XKAXIS = JAXIS
            CASE(KAXIS)
               X2AXIS = IAXIS
               X3AXIS = JAXIS
               ! location in I,J,K od x2,x2,x3 axes:
               XIAXIS = JAXIS; XJAXIS = KAXIS; XKAXIS = IAXIS
            END SELECT

            IF_LOW_HIGH : IF (LOWHIGH == LOW_IND) THEN

               ! Face indexes:
               INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
               INFACE = INDXI1(XIAXIS)
               JNFACE = INDXI1(XJAXIS)
               KNFACE = INDXI1(XKAXIS)

               ! Location of next Cartesian cell:
               INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)-1, IJK(X2AXIS), IJK(X3AXIS) /)
               INCELL = INDXI1(XIAXIS)
               JNCELL = INDXI1(XJAXIS)
               KNCELL = INDXI1(XKAXIS)

               ! Scalar:
               IF (CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKZ) > 0 ) THEN ! next cell is reg-cell:

                  IF(IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS,OZPOS) == 2) CYCLE IFC_LOOP ! CC-REG face already counted in
                                                                                     ! external boundary loop.

                  ! Add face to IBM_RCFACE_Z data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. regular GASPHASE:
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(LOW_IND) = CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKZ)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                  (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND) = &
                  (/ IBM_FTYPE_RGGAS, INCELL, JNCELL, KNCELL /)

                  ! Cell at i+1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKZ(JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                  CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND) = &
                  (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)

                  ! Modify FACE_LIST for the given cut-cell:
                  CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC
               ELSEIF(CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE) THEN ! next cell is cc:

                  ! Test that Cut-cell to Cut-cell reg face hasn't been added before:
                  INLIST = .FALSE.
                  DO IIFC=1,IRC
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(IAXIS)   /= INFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(JAXIS)   /= JNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(KAXIS)   /= KNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(KAXIS+1) /= X1AXIS ) CYCLE
                     INLIST = .TRUE.
                     EXIT
                  ENDDO
                  IF (INLIST) THEN
                     ! This cut-cell is on the high side of face iifc:
                     ! Cell at i+1, i.e. cut-cell:
                     MESHES(NM)%IBM_RCFACE_Z(IIFC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKZ(JCC)
                     MESHES(NM)%IBM_RCFACE_Z(IIFC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                     CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                     MESHES(NM)%IBM_RCFACE_Z(IIFC)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND) = &
                     (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)
                     ! Modify FACE_LIST for the given cut-cell:
                     CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IIFC
                     CYCLE IFC_LOOP
                  ENDIF

                  ! Add face to IBM_RCFACE_Z  data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i+1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(HIGH_IND) = CUT_CELL(ICC)%UNKZ(JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                  CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND) = &
                  (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)

                  ! Modify FACE_LIST for the given cut-cell:
                  CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC
               ENDIF

            ELSE ! IF_LOW_HIGH : HIGH_IND

               ! Face indexes:
               INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS), IJK(X2AXIS), IJK(X3AXIS) /)
               INFACE = INDXI1(XIAXIS)
               JNFACE = INDXI1(XJAXIS)
               KNFACE = INDXI1(XKAXIS)

               ! Location of next Cartesian cell:
               INDXI1(IAXIS:KAXIS) = (/ IJK(X1AXIS)+1, IJK(X2AXIS), IJK(X3AXIS) /)
               INCELL = INDXI1(XIAXIS)
               JNCELL = INDXI1(XJAXIS)
               KNCELL = INDXI1(XKAXIS)

               IF (CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKZ) > 0 ) THEN

                  IF(IJKFACE(INFACE,JNFACE,KNFACE,X1AXIS,OZPOS) == 2) CYCLE IFC_LOOP ! CC-REG face already counted in
                                                                                     ! external boundary loop.

                  ! Add face to IBM_RCFACE_Z data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add all info required for matrix build:
                  ! Cell at i-1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKZ(JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                       CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND) = &
                  (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)
                  ! Modify FACE_LIST for the given cut-cell:
                  CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC

                  ! Cell at i+1, i.e. regular GASPHASE:
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(HIGH_IND) = CCVAR(INCELL,JNCELL,KNCELL,IBM_UNKZ)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,HIGH_IND) = &
                             (/ XCELL(INCELL), YCELL(JNCELL), ZCELL(KNCELL) /)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,HIGH_IND) = &
                  (/ IBM_FTYPE_RGGAS, INCELL, JNCELL, KNCELL /)

               ELSEIF(CCVAR(INCELL,JNCELL,KNCELL,IBM_CGSC) == IBM_CUTCFE) THEN ! next cell is cc:

                  ! Test that Cut-cell to Cut-cell reg face hasn't been added before:
                  INLIST = .FALSE.
                  DO IIFC=1,IRC
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(IAXIS)   /= INFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(JAXIS)   /= JNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(KAXIS)   /= KNFACE ) CYCLE
                     IF ( MESHES(NM)%IBM_RCFACE_Z(IIFC)%IJK(KAXIS+1) /= X1AXIS ) CYCLE
                     INLIST = .TRUE.
                     EXIT
                  ENDDO
                  IF (INLIST) THEN
                     ! This cut-cell is on the high side of face iifc:
                     ! Cell at i-1, i.e. cut-cell:
                     MESHES(NM)%IBM_RCFACE_Z(IIFC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKZ(JCC)
                     MESHES(NM)%IBM_RCFACE_Z(IIFC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                          CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                     MESHES(NM)%IBM_RCFACE_Z(IIFC)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND) = &
                     (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)
                     ! Modify FACE_LIST for the given cut-cell:
                     CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IIFC
                     CYCLE IFC_LOOP
                  ENDIF

                  ! Add face to IBM_RCFACE_Z data structure:
                  IRC = IRC + 1
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%IJK(IAXIS:KAXIS+1) = (/ INFACE, JNFACE, KNFACE, X1AXIS/)

                  ! Can compute Area and centroid location of reg
                  ! face when building matrix.

                  ! Add high cell info required for matrix build:
                  ! Cell at i-1, i.e. cut-cell:
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%UNK(LOW_IND) = CUT_CELL(ICC)%UNKZ(JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%XCEN(IAXIS:KAXIS,LOW_IND) = &
                      CUT_CELL(ICC)%XYZCEN(IAXIS:KAXIS,JCC)
                  MESHES(NM)%IBM_RCFACE_Z(IRC)%CELL_LIST(IAXIS:KAXIS+1,LOW_IND) = &
                  (/ IBM_FTYPE_CFGAS, ICC, JCC, IFC /)
                  ! Modify FACE_LIST for the given cut-cell:
                  CUT_CELL(ICC)%FACE_LIST(4,IFACE) = IRC
               ENDIF
            ENDIF IF_LOW_HIGH

         ENDDO IFC_LOOP

      ENDDO
   ENDDO

   ! Final number of RC faces:
   MESHES(NM)%IBM_NRCFACE_Z = IRC

   ! Cell centered positions and cell sizes:
   IF (ALLOCATED(XCELL)) DEALLOCATE(XCELL)
   IF (ALLOCATED(YCELL)) DEALLOCATE(YCELL)
   IF (ALLOCATED(ZCELL)) DEALLOCATE(ZCELL)
   IF (ALLOCATED(IJKBUFFER)) DEALLOCATE(IJKBUFFER)
   IF (ALLOCATED(LOHIBUFF))  DEALLOCATE(LOHIBUFF)
   IF (ALLOCATED(IJKFACE))   DEALLOCATE(IJKFACE)

ENDDO MAIN_MESH_LOOP


IF (DEBUG_MATVEC_DATA) THEN
   DBG_MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
      CALL MPI_BARRIER(MPI_COMM_WORLD, IERR)
      IF(MY_RANK/=PROCESS(NM)) CYCLE DBG_MESH_LOOP
      CALL POINT_TO_MESH(NM)
      WRITE(LU_ERR,*) ' '
      WRITE(LU_ERR,*) 'MY_RANK, NM : ',MY_RANK,NM
      WRITE(LU_ERR,*) 'IBM_NBBREGFACE(1:3) : ',MESHES(NM)%IBM_NBBREGFACE_Z(IAXIS:KAXIS)
      WRITE(LU_ERR,*) 'IBM_NREGFACE(1:3)   : ',MESHES(NM)%IBM_NREGFACE_Z(IAXIS:KAXIS)
      WRITE(LU_ERR,*) 'IBM_NRCFACE_Z, IBM_NBBRCFACE_Z : ', &
                       MESHES(NM)%IBM_NRCFACE_Z,MESHES(NM)%IBM_NBBRCFACE_Z
   ENDDO DBG_MESH_LOOP
ENDIF

RETURN
END SUBROUTINE GET_GASPHASE_REGFACES_DATA


! ------------------ NUMBER_UNKH_CUTCELLS ---------------------------

SUBROUTINE NUMBER_UNKH_CUTCELLS(FLAG12,NM,NUNKH_LC)

LOGICAL, INTENT(IN) :: FLAG12
INTEGER, INTENT(IN) :: NM
INTEGER, INTENT(INOUT) :: NUNKH_LC(1:NMESHES)

! Local Variables:
INTEGER :: ICC, JCC, NCELL

FLAG12_COND : IF (FLAG12) THEN
   ! Initialize Cut-cell unknown numbers as undefined.
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      CUT_CELL(ICC)%UNKH(:) = IBM_UNDEFINED
   ENDDO
   IF(PRES_ON_CARTESIAN) THEN ! Use Underlying Cartesian cells: Method 2.
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         NUNKH_LC(NM) = NUNKH_LC(NM) + 1
         CUT_CELL(ICC)%UNKH(1) = NUNKH_LC(NM)
      ENDDO
   ELSE ! Unstructured pressure solve: Method 1.
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         NCELL = CUT_CELL(ICC)%NCELL
         DO JCC=1,NCELL
             NUNKH_LC(NM) = NUNKH_LC(NM) + 1
             CUT_CELL(ICC)%UNKH(JCC) = NUNKH_LC(NM)
         ENDDO
      ENDDO
   ENDIF

ELSE
   IF (PRES_ON_CARTESIAN) THEN ! Use Underlying Cartesian cells: Method 2.

      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         CUT_CELL(ICC)%UNKH(1) = CUT_CELL(ICC)%UNKH(1) + UNKH_IND(NM)
      ENDDO

   ELSE ! Unstructured pressure solve: Method 1.

      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         NCELL = CUT_CELL(ICC)%NCELL
         DO JCC=1,NCELL
            CUT_CELL(ICC)%UNKH(JCC) = CUT_CELL(ICC)%UNKH(JCC) + UNKH_IND(NM)
         ENDDO
      ENDDO

   ENDIF

ENDIF FLAG12_COND

RETURN
END SUBROUTINE NUMBER_UNKH_CUTCELLS

! ------------------- COPY_CC_HS_TO_UNKH ----------------------------

SUBROUTINE COPY_CC_HS_TO_UNKH(NM)

INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER :: NOM,ICC,II,JJ,KK,IOR,IW,IIO,JJO,KKO
TYPE (OMESH_TYPE), POINTER :: OM
TYPE (WALL_TYPE), POINTER :: WC
TYPE (EXTERNAL_WALL_TYPE), POINTER :: EWC

IF (PRES_ON_CARTESIAN) THEN ! Use Underlying Cartesian cells: Method 2.

   ! Loop over external wall cells:
   EXTERNAL_WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS

      WC=>WALL(IW)
      EWC=>EXTERNAL_WALL(IW)
      IF (WC%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY) CYCLE EXTERNAL_WALL_LOOP

      II  = WC%ONE_D%II
      JJ  = WC%ONE_D%JJ
      KK  = WC%ONE_D%KK
      IOR = WC%ONE_D%IOR
      NOM = EWC%NOM
      OM => OMESH(NOM)

      ! This assumes all meshes at the same level of refinement:
      KKO=EWC%KKO_MIN
      JJO=EWC%JJO_MIN
      IIO=EWC%IIO_MIN

      ICC=CCVAR(II,JJ,KK,IBM_IDCC)

      IF(.NOT.PRES_ON_WHOLE_DOMAIN) THEN
         IF (ICC > 0) THEN ! Cut-cells on this guard-cell Cartesian cell.
            MESHES(NM)%CUT_CELL(ICC)%UNKH(1) = INT(OM%HS(IIO,JJO,KKO))
         ELSE
            MESHES(NM)%CCVAR(II,JJ,KK,IBM_UNKH) = INT(OM%HS(IIO,JJO,KKO))
         ENDIF
      ELSE
         MESHES(NM)%CCVAR(II,JJ,KK,IBM_UNKH) = INT(OM%HS(IIO,JJO,KKO))
         IF (ICC > 0) MESHES(NM)%CUT_CELL(ICC)%UNKH(1) = MESHES(NM)%CCVAR(II,JJ,KK,IBM_UNKH)
      ENDIF


      OM%HS(IIO,JJO,KKO) = 0._EB ! (VAR_CC == UNKH)

   ENDDO EXTERNAL_WALL_LOOP

ELSE

   ! Unstructured pressure solve: Method 1.
   WRITE(LU_ERR,*) 'COPY_CC_UNKH_TO_HS Error: Unstructured pressure solve not implemented yet.'

ENDIF

RETURN
END SUBROUTINE COPY_CC_HS_TO_UNKH

! ------------------- COPY_CC_UNKH_TO_HS ----------------------------

SUBROUTINE COPY_CC_UNKH_TO_HS(NM)

INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER :: I,J,K,ICC

IF (PRES_ON_CARTESIAN) THEN ! Use Underlying Cartesian cells: Method 2.

   IF(.NOT.PRES_ON_WHOLE_DOMAIN) THEN
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I = MESHES(NM)%CUT_CELL(ICC)%IJK(IAXIS)
         J = MESHES(NM)%CUT_CELL(ICC)%IJK(JAXIS)
         K = MESHES(NM)%CUT_CELL(ICC)%IJK(KAXIS)
         HS(I,J,K)= REAL(MESHES(NM)%CUT_CELL(ICC)%UNKH(1),EB)
      ENDDO
   ELSE
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I = MESHES(NM)%CUT_CELL(ICC)%IJK(IAXIS)
         J = MESHES(NM)%CUT_CELL(ICC)%IJK(JAXIS)
         K = MESHES(NM)%CUT_CELL(ICC)%IJK(KAXIS)
         MESHES(NM)%CUT_CELL(ICC)%UNKH(1) = INT(HS(I,J,K))
      ENDDO
   ENDIF

ELSE

   ! Unstructured pressure solve: Method 1.
   WRITE(LU_ERR,*) 'COPY_CC_UNKH_TO_HS Error: Unstructured pressure solve not implemented yet.'

ENDIF



RETURN
END SUBROUTINE COPY_CC_UNKH_TO_HS


! ------------------ GET_MATRIX_INDEXES_Z ---------------------------
SUBROUTINE GET_MATRIX_INDEXES_Z
USE MPI_F08

! Local variables:
INTEGER :: NM
INTEGER :: ILO,IHI,JLO,JHI,KLO,KHI
INTEGER :: I,J,K,ICC,JCC,NCELL,INGH,JNGH,KNGH,IERR,IPT
INTEGER, PARAMETER :: IMPADD = 1
INTEGER, PARAMETER :: SHFTM(1:3,1:6) = RESHAPE((/-1,0,0,1,0,0,0,-1,0,0,1,0,0,0,-1,0,0,1/),(/3,6/))
LOGICAL :: CRTCELL_FLG

INTEGER :: X1AXIS,LOWHIGH,ILH,IFC,IFACE,IFC2,IFACE2,ICC2,JCC2,VAL_UNKZ
REAL(EB):: CCVOL_THRES,VAL_CVOL

LOGICAL :: QUITLINK_FLG

! Linking variables associated data:
LOGICAL, SAVE :: UNLINKED_1ST_CALL=.TRUE.
INTEGER :: LINK_ITER, ULINK_COUNT, II, JJ, KK
CHARACTER(MESSAGE_LENGTH) :: UNLINKED_FILE
REAL(EB) :: DV, DISTCELL
INTEGER, PARAMETER :: N_LINK_ATTMP = 50

INTEGER, ALLOCATABLE, DIMENSION(:) :: CELLPUNKZ, INDUNKZ
INTEGER :: COUNT, ICF, CF_STATUS

! Define local number of cut-cell:
IF (ALLOCATED(NUNKZ_LOC)) DEALLOCATE(NUNKZ_LOC)
ALLOCATE(NUNKZ_LOC(1:NMESHES)); NUNKZ_LOC = 0

! Cell numbers for Scalar equations:
MAIN_MESH_LOOP : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! Mesh sizes:
   NXB=IBAR
   NYB=JBAR
   NZB=KBAR

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.
   ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
   IHI_CELL = IHI_FACE ! Last internal cell index.

   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.
   JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
   JHI_CELL = JHI_FACE ! Last internal cell index.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.
   KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
   KHI_CELL = KHI_FACE ! Last internal cell index.

   ! Initialize unknown numbers for Z:
   ! We assume SET_CUTCELLS_3D has been called and CCVAR has been allocated:
   CCVAR(:,:,:,IBM_UNKZ) = IBM_UNDEFINED
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      CUT_CELL(ICC)%UNKZ(:) = IBM_UNDEFINED
   ENDDO

   ! 1. Number regular GASPHASE cells:
   ILO = ILO_CELL; IHI = IHI_CELL
   JLO = JLO_CELL; JHI = JHI_CELL
   KLO = KLO_CELL; KHI = KHI_CELL

   IF (PERIODIC_TEST==103 .OR. PERIODIC_TEST==11 .OR. PERIODIC_TEST==7) THEN
      DO K=KLO,KHI
         DO J=JLO,JHI
            DO I=ILO,IHI
               ! If regular cell centroid is outside the test box + DELTA -> drop:
               IF(XC(I) < (VAL_TESTX_LOW-DX(I) +GEOMEPS)) CYCLE; IF(XC(I) > (VAL_TESTX_HIGH+DX(I)-GEOMEPS)) CYCLE
               IF(YC(J) < (VAL_TESTY_LOW-DY(J) +GEOMEPS)) CYCLE; IF(YC(J) > (VAL_TESTY_HIGH+DY(J)-GEOMEPS)) CYCLE
               IF(ZC(K) < (VAL_TESTZ_LOW-DZ(K) +GEOMEPS)) CYCLE; IF(ZC(K) > (VAL_TESTZ_HIGH+DZ(K)-GEOMEPS)) CYCLE
               IF(CCVAR(I,J,K,IBM_CGSC) /= IBM_GASPHASE) CYCLE
               NUNKZ_LOC(NM) = NUNKZ_LOC(NM) + 1
               CCVAR(I,J,K,IBM_UNKZ) = NUNKZ_LOC(NM)
            ENDDO
         ENDDO
      ENDDO
   ENDIF

   ! Loop on Cartesian cells, number unknowns for cells type IBM_CUTCFE and surrounding IBM_GASPHASE:
   DO K=KLO-1,KHI+1
      DO J=JLO-1,JHI+1
         DO I=ILO-1,IHI+1
            ! Drop if cartesian cell is not type IBM_CUTCFE:
            IF (  CCVAR(I,J,K,IBM_CGSC) /= IBM_CUTCFE ) CYCLE

            ! First Add the Cut-Cell
            ICC  = CCVAR(I,J,K,IBM_IDCC)
            IF (ICC <= MESHES(NM)%N_CUTCELL_MESH .AND. .NOT.SOLID(CELL_INDEX(I,J,K)) ) THEN ! Don't number guard-cell cut-cells,
               NCELL= CUT_CELL(ICC)%NCELL                                                   ! or cutcells inside an OBST.
               CCVOL_THRES = CCVOL_LINK*DX(I)*DY(J)*DZ(K)
               DO JCC=1,NCELL
                  IF ( CUT_CELL(ICC)%VOLUME(JCC) < CCVOL_THRES) CYCLE ! Small cell, dealt with later.
                  NUNKZ_LOC(NM) = NUNKZ_LOC(NM) + 1
                  CUT_CELL(ICC)%UNKZ(JCC) = NUNKZ_LOC(NM)
               ENDDO
            ENDIF

            ! First Run over Neighbors: Case 27 cells.
            SELECT CASE(IMPADD)
            CASE(0)
               ! No corner neighbors, only 6 face neighbors of Cartesian cell.
               DO IPT=1,6
                  KNGH=K+SHFTM(KAXIS,IPT)
                  IF ( (KNGH < KLO_CELL) .OR. (KNGH > KHI_CELL) ) CYCLE
                  JNGH=J+SHFTM(JAXIS,IPT)
                  IF ( (JNGH < JLO_CELL) .OR. (JNGH > JHI_CELL) ) CYCLE
                  INGH=I+SHFTM(IAXIS,IPT)
                  ! Either not GASPHASE or already counted:
                  IF ( (CCVAR(INGH,JNGH,KNGH,IBM_CGSC) /= IBM_GASPHASE) .OR. &
                       (CCVAR(INGH,JNGH,KNGH,IBM_UNKZ)  > 0) ) CYCLE
                  IF ( (INGH < ILO_CELL) .OR. (INGH > IHI_CELL) ) CYCLE

                  ! Don't number a regular cell inside an OBST:
                  IF (SOLID(CELL_INDEX(INGH,JNGH,KNGH))) CYCLE

                  ! Add Scalar unknown:
                  NUNKZ_LOC(NM) = NUNKZ_LOC(NM) + 1
                  CCVAR(INGH,JNGH,KNGH,IBM_UNKZ) = NUNKZ_LOC(NM)
               ENDDO

            CASE DEFAULT
               ! Only Internal cells for the mesh in the stencil (I-IMPADD:I+IMPADD,J-IMPADD:J+IMPADD,K-IMPADD:K+IMPADD)
               ! aound Cartesian cell I,J,K of type IBM_CUTCFE:
               DO KNGH=K-IMPADD,K+IMPADD
                  IF ( (KNGH < KLO_CELL) .OR. (KNGH > KHI_CELL) ) CYCLE
                  DO JNGH=J-IMPADD,J+IMPADD
                     IF ( (JNGH < JLO_CELL) .OR. (JNGH > JHI_CELL) ) CYCLE
                     DO INGH=I-IMPADD,I+IMPADD
                        ! Either not GASPHASE or already counted:
                        IF ( (CCVAR(INGH,JNGH,KNGH,IBM_CGSC) /= IBM_GASPHASE) .OR. &
                             (CCVAR(INGH,JNGH,KNGH,IBM_UNKZ)  > 0) ) CYCLE
                        IF ( (INGH < ILO_CELL) .OR. (INGH > IHI_CELL) ) CYCLE

                        ! Don't number a regular cell inside an OBST:
                        IF (SOLID(CELL_INDEX(INGH,JNGH,KNGH))) CYCLE

                        ! Add Scalar unknown:
                        NUNKZ_LOC(NM) = NUNKZ_LOC(NM) + 1
                        CCVAR(INGH,JNGH,KNGH,IBM_UNKZ) = NUNKZ_LOC(NM)
                     ENDDO
                  ENDDO
               ENDDO
            END SELECT

         ENDDO
      ENDDO
   ENDDO

ENDDO MAIN_MESH_LOOP

! Now link small cells to surrounding cells in the mesh:
! NOTE: This linking scheme assumes there are no small cells trapped against a block boundary, i.e. there is a path
! within the mesh between them and a large cell.
! NOTE2: Two remediation methods are used to link small cells trapped against a block boundary:
! 1. Try linking them to the closest cell regular cell with UNKZ > 0.
! 2. Set for Mass matrix entry the cut-cell volume to ~ a cartesian cell and give a UNKZ > 0 to said cut-cell.
!    This is done setting MESH(NM)%CUT_CELL(ICC)%USE_CC_VOL(JCC) = .FALSE., which will be used when building the
!    Mass matrix.
! NOTE3: This scheme links two unknowns local to the mesh, therefore parallel consistency is not maintained.
MAIN_MESH_LOOP3 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! Small Cell linking scheme:
   ! 1. Attempt to link to Regular GASPHASE cells with unknown UNKZ > 0.
   ! 2. Attempt to link to large or already linked cut-cells.
   ! 3. If there are unlinked cells after N_LINK_ATTMP:
   !    3.a 1st Try : Link to closest UNKZ > 0 regular cell in the mesh.
   !    3.b 2nd Try : Give small cell a local unknown number, set CUT_CELL(ICC)%USE_CC_VOL(JCC)=.FALSE., such that
   !                  its volume in mass matrix is CCVOL_THRES.
   ! Set counter to 0:
   LINK_ITER = 0
   LINK_LOOP : DO ! Cut-cell linking loop for small cells. -> Algo defined by CCVOL_LINK.

      QUITLINK_FLG = .TRUE.

      ! First attempt to link to regular GASPHASE cells:
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I = CUT_CELL(ICC)%IJK(IAXIS)
         J = CUT_CELL(ICC)%IJK(JAXIS)
         K = CUT_CELL(ICC)%IJK(KAXIS)
         ! Don't attempt to link cut-cells inside an OBST:
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
         NCELL = CUT_CELL(ICC)%NCELL
         CCVOL_THRES = CCVOL_LINK*DX(I)*DY(J)*DZ(K)
         DO JCC=1,NCELL
            IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
            ! Small cells, get IBM_UNKZ from a large cell neighbor:
            VAL_UNKZ = IBM_UNDEFINED
            VAL_CVOL = CCVOL_THRES
            IFC_LOOP3A : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
               IFACE   = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
               LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
               ILH     = 2*LOWHIGH - 3 ! -1 for LOW_IND, 1 for HIGH_IND
               SELECT CASE(CUT_CELL(ICC)%FACE_LIST(1,IFACE)) ! 1. Check if a surrounding cell is a regular cell:
               CASE(IBM_FTYPE_RGGAS) ! REGULAR GASPHASE
                  X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)
                  CRTCELL_FLG = .FALSE.
                  SELECT CASE(X1AXIS)
                  ! Using IBM_UNKZ in the following conditionals assures no guard-cells outside of the domain (except
                  ! case of periodic boundaries) are chosen. Deals with domain BCs.
                  CASE(IAXIS)
                     IF(CCVAR(I+ILH,J,K,IBM_UNKZ) > 0) THEN ! Regular Cartesian Cell
                        VAL_UNKZ = CCVAR(I+ILH,J,K,IBM_UNKZ)
                        CRTCELL_FLG = .TRUE.
                     ENDIF
                  CASE(JAXIS)
                     IF(CCVAR(I,J+ILH,K,IBM_UNKZ) > 0) THEN ! Regular Cartesian Cell
                        VAL_UNKZ = CCVAR(I,J+ILH,K,IBM_UNKZ)
                        CRTCELL_FLG = .TRUE.
                     ENDIF
                  CASE(KAXIS)
                     IF(CCVAR(I,J,K+ILH,IBM_UNKZ) > 0) THEN ! Regular Cartesian Cell
                        VAL_UNKZ = CCVAR(I,J,K+ILH,IBM_UNKZ)
                        CRTCELL_FLG = .TRUE.
                     ENDIF
                  END SELECT
                  IF ( CRTCELL_FLG ) EXIT IFC_LOOP3A

               END SELECT
            ENDDO IFC_LOOP3A
            CUT_CELL(ICC)%UNKZ(JCC) = VAL_UNKZ
         ENDDO
      ENDDO

      ! Then attempt to connect to large cut-cells, or already connected small cells (CUT_CELL(OCC)%UNKZ(JCC) > 0):
      DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
         I = CUT_CELL(ICC)%IJK(IAXIS)
         J = CUT_CELL(ICC)%IJK(JAXIS)
         K = CUT_CELL(ICC)%IJK(KAXIS)
         ! Don't attempt to link cut-cells inside an OBST:
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
         NCELL = CUT_CELL(ICC)%NCELL
         CCVOL_THRES = CCVOL_LINK*DX(I)*DY(J)*DZ(K)
         DO JCC=1,NCELL
            IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE

            ! Small cells, get IBM_UNKZ from a large cell neighbor:
            VAL_UNKZ = IBM_UNDEFINED
            VAL_CVOL = -GEOMEPS
            IFC_LOOP3 : DO IFC=1,CUT_CELL(ICC)%CCELEM(1,JCC)
               IFACE   = CUT_CELL(ICC)%CCELEM(IFC+1,JCC)
               IF((CUT_CELL(ICC)%FACE_LIST(1,IFACE)==IBM_FTYPE_CFINB) .OR. &
                  (CUT_CELL(ICC)%FACE_LIST(1,IFACE)==IBM_FTYPE_SVERT)) CYCLE IFC_LOOP3
               LOWHIGH = CUT_CELL(ICC)%FACE_LIST(2,IFACE)
               ILH     = 2*LOWHIGH - 3 ! -1 for LOW_IND, 1 for HIGH_IND

               ! Cycle if surrounding cell is located in the guard-cell region, if so drop, as we don't have
               ! at this point unknown numbers on guard-cells/guard-cell ccs:
               X1AXIS  = CUT_CELL(ICC)%FACE_LIST(3,IFACE)
               SELECT CASE(X1AXIS)
               CASE(IAXIS)
                  IF( (I+ILH < 1) .OR. (I+ILH > IBAR) ) CYCLE IFC_LOOP3
               CASE(JAXIS)
                  IF( (J+ILH < 1) .OR. (J+ILH > JBAR) ) CYCLE IFC_LOOP3
               CASE(KAXIS)
                  IF( (K+ILH < 1) .OR. (K+ILH > KBAR) ) CYCLE IFC_LOOP3
               END SELECT

               SELECT CASE(CUT_CELL(ICC)%FACE_LIST(1,IFACE)) ! 1. Check if a surrounding cell is a regular cell:
               CASE(IBM_FTYPE_RGGAS) ! REGULAR GASPHASE
                  SELECT CASE(X1AXIS)
                  CASE(IAXIS)
                     IF(CCVAR(I+ILH,J,K,IBM_UNKZ) <= 0) THEN ! Cut - cell. Array IBM_RCFACE_VEL is used.
                        CALL GET_ICC2_JCC2(ICC,IFACE,I+ILH,J,K,ICC2,JCC2)
                        IF ( ANY((/ ICC2, JCC2 /) == 0) ) CYCLE IFC_LOOP3
                        IF ( CUT_CELL(ICC2)%VOLUME(JCC2) < VAL_CVOL) CYCLE IFC_LOOP3
                        IF ( CUT_CELL(ICC2)%UNKZ(JCC2) <= 0) CYCLE IFC_LOOP3
                        VAL_CVOL = CUT_CELL(ICC2)%VOLUME(JCC2)
                        VAL_UNKZ = CUT_CELL(ICC2)%UNKZ(JCC2)
                     ENDIF
                  CASE(JAXIS)
                     IF(CCVAR(I,J+ILH,K,IBM_UNKZ) <= 0) THEN ! Cut - cell. Array IBM_RCFACE_VEL is used.
                        CALL GET_ICC2_JCC2(ICC,IFACE,I,J+ILH,K,ICC2,JCC2)
                        IF ( ANY((/ ICC2, JCC2 /) == 0) ) CYCLE IFC_LOOP3
                        IF ( CUT_CELL(ICC2)%VOLUME(JCC2) < VAL_CVOL) CYCLE IFC_LOOP3
                        IF ( CUT_CELL(ICC2)%UNKZ(JCC2) <= 0) CYCLE IFC_LOOP3
                        VAL_CVOL = CUT_CELL(ICC2)%VOLUME(JCC2)
                        VAL_UNKZ = CUT_CELL(ICC2)%UNKZ(JCC2)
                     ENDIF
                  CASE(KAXIS)
                     IF(CCVAR(I,J,K+ILH,IBM_UNKZ) <= 0) THEN ! Cut - cell. Array IBM_RCFACE_VEL is used.
                        CALL GET_ICC2_JCC2(ICC,IFACE,I,J,K+ILH,ICC2,JCC2)
                        IF ( ANY((/ ICC2, JCC2 /) == 0) ) CYCLE IFC_LOOP3
                        IF ( CUT_CELL(ICC2)%VOLUME(JCC2) < VAL_CVOL) CYCLE IFC_LOOP3
                        IF ( CUT_CELL(ICC2)%UNKZ(JCC2) <= 0) CYCLE IFC_LOOP3
                        VAL_CVOL = CUT_CELL(ICC2)%VOLUME(JCC2)
                        VAL_UNKZ = CUT_CELL(ICC2)%UNKZ(JCC2)
                     ENDIF
                  END SELECT
               CASE(IBM_FTYPE_CFGAS) ! 2. Check for large surrounding cut-cells:

                  IFC2    = CUT_CELL(ICC)%FACE_LIST(4,IFACE)
                  IFACE2  = CUT_CELL(ICC)%FACE_LIST(5,IFACE)

                  ICC2    = CUT_FACE(IFC2)%CELL_LIST(2,LOWHIGH,IFACE2)
                  JCC2    = CUT_FACE(IFC2)%CELL_LIST(3,LOWHIGH,IFACE2)

                  IF ( CUT_CELL(ICC2)%VOLUME(JCC2) < VAL_CVOL) CYCLE IFC_LOOP3
                  IF ( CUT_CELL(ICC2)%UNKZ(JCC2) <= 0) CYCLE IFC_LOOP3

                  VAL_CVOL = CUT_CELL(ICC2)%VOLUME(JCC2)
                  VAL_UNKZ = CUT_CELL(ICC2)%UNKZ(JCC2)
               END SELECT
            ENDDO IFC_LOOP3

            ! This small cut-cell still has an undefined unknown, redo link-loop to test for updated unknown number on
            ! neighbors:
            IF (VAL_UNKZ <= 0) THEN
               QUITLINK_FLG = .FALSE.
            ENDIF
            CUT_CELL(ICC)%UNKZ(JCC) = VAL_UNKZ
         ENDDO
      ENDDO

      ! Then attempt to connect to large cut-cells, or already connected small cells (CUT_CELL(OCC)%UNKZ(JCC) > 0):
       DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
          I = CUT_CELL(ICC)%IJK(IAXIS)
          J = CUT_CELL(ICC)%IJK(JAXIS)
          K = CUT_CELL(ICC)%IJK(KAXIS)
          ! Don't attempt to link cut-cells inside an OBST:
          IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
          NCELL = CUT_CELL(ICC)%NCELL
          ! For cases with more than one cut-cell, define UNKZ of all cells to be the one of first cut-cell
          ! with UNKZ > 0:
          DO JCC=1,NCELL
             IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) EXIT
          ENDDO
          IF (JCC <= NCELL) THEN
             VAL_UNKZ = CUT_CELL(ICC)%UNKZ(JCC)
             CUT_CELL(ICC)%UNKZ(1:NCELL) = VAL_UNKZ
          ENDIF
       ENDDO

      IF (QUITLINK_FLG) EXIT LINK_LOOP

      LINK_ITER = LINK_ITER + 1
      IF (LINK_ITER > N_LINK_ATTMP) THEN
          ! Count how many unlinked cells we have in this mesh:
          ULINK_COUNT = 0
          DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
             I = CUT_CELL(ICC)%IJK(IAXIS)
             J = CUT_CELL(ICC)%IJK(JAXIS)
             K = CUT_CELL(ICC)%IJK(KAXIS)
             ! Don't count cut-cells inside an OBST:
             IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
             NCELL = CUT_CELL(ICC)%NCELL
             DO JCC=1,NCELL
                IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
                ULINK_COUNT = ULINK_COUNT + 1
             ENDDO
          ENDDO

          ! Write out unlinked cells properties:
          ! Open file to write unlinked cells:
          WRITE(UNLINKED_FILE,'(A,A,I0,A)') TRIM(CHID),'_unlinked_',MY_RANK,'.log'
          ! Create file:
          IF (UNLINKED_1ST_CALL) THEN
             OPEN(UNIT=LU_UNLNK,FILE=TRIM(UNLINKED_FILE),STATUS='UNKNOWN')
             WRITE(LU_UNLNK,*) 'Unlinked cut-cell Information for Process=',MY_RANK
             CLOSE(LU_UNLNK)
             UNLINKED_1ST_CALL = .FALSE.
          ENDIF
          ! Open file to write unlinked cell information:
          OPEN(UNIT=LU_UNLNK,FILE=TRIM(UNLINKED_FILE),STATUS='OLD',POSITION='APPEND')
          WRITE(LU_UNLNK,*) ' '
          WRITE(LU_UNLNK,'(A,I4,A,I4)') ' Mesh NM=',NM,', number of unlinked cells=',ULINK_COUNT

          ! Dump info:
          ULINK_COUNT = 0
          DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
             I = CUT_CELL(ICC)%IJK(IAXIS)
             J = CUT_CELL(ICC)%IJK(JAXIS)
             K = CUT_CELL(ICC)%IJK(KAXIS)
             ! Don't count cut-cells inside an OBST:
             IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
             NCELL = CUT_CELL(ICC)%NCELL
             CCVOL_THRES = CCVOL_LINK*DX(I)*DY(J)*DZ(K)
             DO JCC=1,NCELL
                IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
                ULINK_COUNT = ULINK_COUNT + 1
                WRITE(LU_UNLNK,'(I5,A,5I5,A,5F16.8)') &
                ULINK_COUNT,', I,J,K,ICC,JCC=',I,J,K,ICC,JCC,', X,Y,Z,CCVOL,CCVOL_CRT=',X(I),Y(J),Z(K), &
                CUT_CELL(ICC)%VOLUME(JCC),DX(I)*DY(J)*DZ(K)
             ENDDO
          ENDDO
          CLOSE(LU_UNLNK)

          ! 1st Try: Link each cell to closest unknown numbered regular cell in the mesh:
          DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
             I = CUT_CELL(ICC)%IJK(IAXIS)
             J = CUT_CELL(ICC)%IJK(JAXIS)
             K = CUT_CELL(ICC)%IJK(KAXIS)
             ! Drop cut-cells inside an OBST:
             IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
             NCELL = CUT_CELL(ICC)%NCELL
             DO JCC=1,NCELL
                IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
                DISTCELL=1._EB/GEOMEPS
                ! 3D LOOP over regular cells:
                DO KK=1,KBAR
                   DO JJ=1,JBAR
                      DO II=1,IBAR
                         IF(CCVAR(II,JJ,KK,IBM_UNKZ) <= 0) CYCLE
                         DV = SQRT( (X(II)-X(I))**2._EB + (Y(JJ)-Y(J))**2._EB + (Z(KK)-Z(K))**2._EB )
                         IF ( DV-GEOMEPS > DISTCELL ) CYCLE
                         DISTCELL=DV
                         CUT_CELL(ICC)%UNKZ(JCC) = CCVAR(II,JJ,KK,IBM_UNKZ) ! Assign reg cell unknown number
                      ENDDO
                   ENDDO
                ENDDO
             ENDDO
          ENDDO

          ! Recount unlinked cells (i.e. no other viable cells in the mesh).
          ULINK_COUNT = 0
          DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
             I = CUT_CELL(ICC)%IJK(IAXIS)
             J = CUT_CELL(ICC)%IJK(JAXIS)
             K = CUT_CELL(ICC)%IJK(KAXIS)
             ! Drop cut-cells inside an OBST:
             IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
             NCELL = CUT_CELL(ICC)%NCELL
             DO JCC=1,NCELL
                IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
                ULINK_COUNT = ULINK_COUNT + 1
             ENDDO
          ENDDO

          ! Write out remaining unlinked cells properties.
          ! Open file to write unlinked cell information:
          OPEN(UNIT=LU_UNLNK,FILE=TRIM(UNLINKED_FILE),STATUS='OLD',POSITION='APPEND')
          WRITE(LU_UNLNK,*) ' '
          WRITE(LU_UNLNK,*) 'STATUS AFTER CUT-CELL REGION REGULAR CELL CARTESIAN SEARCH:'
          WRITE(LU_UNLNK,'(A,I4,A,I4)') ' Mesh NM=',NM,', number of unlinked cells after REG CELL approx=',ULINK_COUNT
          IF(ULINK_COUNT > 0) THEN
             ! Dump info:
             ULINK_COUNT = 0
             DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
                I = CUT_CELL(ICC)%IJK(IAXIS)
                J = CUT_CELL(ICC)%IJK(JAXIS)
                K = CUT_CELL(ICC)%IJK(KAXIS)
                ! Drop cut-cells inside an OBST:
                IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
                NCELL = CUT_CELL(ICC)%NCELL
                CCVOL_THRES = CCVOL_LINK*DX(I)*DY(J)*DZ(K)
                DO JCC=1,NCELL
                   IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
                   ULINK_COUNT = ULINK_COUNT + 1
                   WRITE(LU_UNLNK,'(I5,A,5I5,A,5F16.8)') &
                   ULINK_COUNT,', I,J,K,ICC,JCC=',I,J,K,ICC,JCC,', X,Y,Z,CCVOL,CCVOL_CRT=',X(I),Y(J),Z(K), &
                   CUT_CELL(ICC)%VOLUME(JCC),DX(I)*DY(J)*DZ(K)
                ENDDO
             ENDDO
          ENDIF
          CLOSE(LU_UNLNK)

          IF (ULINK_COUNT == 0) EXIT LINK_LOOP

          ! 2nd Try : Loop over cut cells and give the ramining unlinked cells a UNKZ>0,
          ! plus CUT_CELL(ICC)%USE_CC_VOL(JCC) = .FALSE.:
          DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
             I = CUT_CELL(ICC)%IJK(IAXIS)
             J = CUT_CELL(ICC)%IJK(JAXIS)
             K = CUT_CELL(ICC)%IJK(KAXIS)
             ! Drop cut-cells inside an OBST:
             IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
             NCELL = CUT_CELL(ICC)%NCELL
             DO JCC=1,NCELL
                IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
                NUNKZ_LOC(NM) = NUNKZ_LOC(NM) + 1
                CUT_CELL(ICC)%UNKZ(JCC) = NUNKZ_LOC(NM)
                CUT_CELL(ICC)%USE_CC_VOL(JCC) = .FALSE.
             ENDDO
          ENDDO

          ! Recount unlinked cells (i.e. no other viable cells in the mesh).
          ULINK_COUNT = 0
          DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
             I = CUT_CELL(ICC)%IJK(IAXIS)
             J = CUT_CELL(ICC)%IJK(JAXIS)
             K = CUT_CELL(ICC)%IJK(KAXIS)
             ! Drop cut-cells inside an OBST:
             IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
             NCELL = CUT_CELL(ICC)%NCELL
             DO JCC=1,NCELL
                IF ( CUT_CELL(ICC)%UNKZ(JCC) > 0 ) CYCLE
                ULINK_COUNT = ULINK_COUNT + 1
             ENDDO
          ENDDO

          ! Write out final status:
          OPEN(UNIT=LU_UNLNK,FILE=TRIM(UNLINKED_FILE),STATUS='OLD',POSITION='APPEND')
          WRITE(LU_UNLNK,*) ' '
          WRITE(LU_UNLNK,*) 'STATUS AFTER SMALL CUT-CELL CUT_CELL(ICC)%USE_CC_VOL(JCC) change to .FALSE.:'
          WRITE(LU_UNLNK,'(A,I4,A,I4)') ' Mesh NM=',NM,', number of unlinked cells after Vol change approx=',ULINK_COUNT
          CLOSE(LU_UNLNK)

          EXIT LINK_LOOP
      ENDIF
   ENDDO LINK_LOOP

ENDDO MAIN_MESH_LOOP3

! After fixing cut-cell unkz for a given Cartesian cells there might be UNKZ values that haven't been assigned.
! Condense:
MAIN_MESH_LOOP31 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   IF(NUNKZ_LOC(NM) == 0) CYCLE
   CALL POINT_TO_MESH(NM)

   ALLOCATE(CELLPUNKZ(1:NUNKZ_LOC(NM)), INDUNKZ(1:NUNKZ_LOC(NM))); CELLPUNKZ = 0; INDUNKZ = 0;
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF(CCVAR(I,J,K,IBM_UNKZ) < 1) CYCLE
            CELLPUNKZ(CCVAR(I,J,K,IBM_UNKZ)) = CELLPUNKZ(CCVAR(I,J,K,IBM_UNKZ)) + 1
         ENDDO
      ENDDO
   ENDDO
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         IF (CUT_CELL(ICC)%UNKZ(JCC) < 1) CYCLE
         CELLPUNKZ(CUT_CELL(ICC)%UNKZ(JCC)) = CELLPUNKZ(CUT_CELL(ICC)%UNKZ(JCC)) + 1
      ENDDO
   ENDDO

   ! Now re-index:
   COUNT=0
   DO I=1,NUNKZ_LOC(NM)
      IF(CELLPUNKZ(I) == 0) CYCLE ! This UNKZ_LOC value has no cells associated to it.
      COUNT = COUNT + 1
      INDUNKZ(I) = COUNT
   ENDDO
   NUNKZ_LOC(NM) = COUNT

   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF(CCVAR(I,J,K,IBM_UNKZ) < 1) CYCLE
            VAL_UNKZ = CCVAR(I,J,K,IBM_UNKZ)
            CCVAR(I,J,K,IBM_UNKZ) = INDUNKZ(VAL_UNKZ) ! Condensed value.
         ENDDO
      ENDDO
   ENDDO
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         IF (CUT_CELL(ICC)%UNKZ(JCC) < 1) CYCLE
         VAL_UNKZ = CUT_CELL(ICC)%UNKZ(JCC)
         CUT_CELL(ICC)%UNKZ(JCC) = INDUNKZ(VAL_UNKZ) ! Condensed value.
      ENDDO
   ENDDO
   DEALLOCATE(CELLPUNKZ,INDUNKZ)

ENDDO MAIN_MESH_LOOP31



! Define total number of unknowns and global unknown index start per MESH:
IF (ALLOCATED(NUNKZ_TOT)) DEALLOCATE(NUNKZ_TOT)
ALLOCATE(NUNKZ_TOT(1:NMESHES)); NUNKZ_TOT = 0
IF (N_MPI_PROCESSES > 1) THEN
   CALL MPI_ALLREDUCE(NUNKZ_LOC, NUNKZ_TOT, NMESHES, MPI_INTEGER, MPI_SUM, MPI_COMM_WORLD, IERR)
ELSE
   NUNKZ_TOT = NUNKZ_LOC
ENDIF
! Define global start indexes for each mesh:
IF (ALLOCATED(UNKZ_ILC)) DEALLOCATE(UNKZ_ILC)
ALLOCATE(UNKZ_ILC(1:NMESHES)); UNKZ_ILC(1:NMESHES) = 0
IF (ALLOCATED(UNKZ_IND)) DEALLOCATE(UNKZ_IND)
ALLOCATE(UNKZ_IND(1:NMESHES)); UNKZ_IND(1:NMESHES) = 0
DO NM=2,NMESHES
   UNKZ_ILC(NM) = UNKZ_ILC(NM-1) + NUNKZ_LOC(NM-1)
   UNKZ_IND(NM) = UNKZ_IND(NM-1) + NUNKZ_TOT(NM-1)
ENDDO

! Cell numbers for Scalar equations in global numeration:
MAIN_MESH_LOOP2 : DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX

   CALL POINT_TO_MESH(NM)

   ! Mesh sizes:
   NXB=IBAR; NYB=JBAR; NZB=KBAR

   ! X direction bounds:
   ILO_FACE = 0                    ! Low mesh boundary face index.
   IHI_FACE = IBAR                 ! High mesh boundary face index.
   ILO_CELL = ILO_FACE + 1     ! First internal cell index. See notes.
   IHI_CELL = IHI_FACE ! Last internal cell index.

   ! Y direction bounds:
   JLO_FACE = 0                    ! Low mesh boundary face index.
   JHI_FACE = JBAR                 ! High mesh boundary face index.
   JLO_CELL = JLO_FACE + 1     ! First internal cell index. See notes.
   JHI_CELL = JHI_FACE ! Last internal cell index.

   ! Z direction bounds:
   KLO_FACE = 0                    ! Low mesh boundary face index.
   KHI_FACE = KBAR                 ! High mesh boundary face index.
   KLO_CELL = KLO_FACE + 1     ! First internal cell index. See notes.
   KHI_CELL = KHI_FACE ! Last internal cell index.

   ! 1. Number regular GASPHASE cells within the implicit region:
   ILO = ILO_CELL; IHI = IHI_CELL
   JLO = JLO_CELL; JHI = JHI_CELL
   KLO = KLO_CELL; KHI = KHI_CELL
   DO K=KLO,KHI
      DO J=JLO,JHI
         DO I=ILO,IHI
            IF (CCVAR(I,J,K,IBM_CGSC) /= IBM_GASPHASE) CYCLE
            IF (CCVAR(I,J,K,IBM_UNKZ) <= 0 ) CYCLE ! Drop if regular GASPHASE cell has not been assigned unknown number.
            CCVAR(I,J,K,IBM_UNKZ) = CCVAR(I,J,K,IBM_UNKZ) + UNKZ_IND(NM)
         ENDDO
      ENDDO
   ENDDO
   ! 2. Number cut-cells:
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      I = CUT_CELL(ICC)%IJK(IAXIS)
      J = CUT_CELL(ICC)%IJK(JAXIS)
      K = CUT_CELL(ICC)%IJK(KAXIS)
      ! Drop cut-cells inside an OBST:
      IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
      NCELL = MESHES(NM)%CUT_CELL(ICC)%NCELL
      CCVOL_THRES = CCVOL_LINK*DX(I)*DY(J)*DZ(K)
      DO JCC=1,NCELL
         CUT_CELL(ICC)%UNKZ(JCC) = CUT_CELL(ICC)%UNKZ(JCC) + UNKZ_IND(NM)
      ENDDO
   ENDDO

ENDDO MAIN_MESH_LOOP2

! Exchange Guardcell + guard cc information on IBM_UNKZ:
CALL FILL_UNKZ_GUARDCELLS

! finally set to solid Gasphase cut-faces which have a surrounding cut-cell inside an OBST:
DO NM=LOWER_MESH_INDEX,UPPER_MESH_INDEX
   CALL POINT_TO_MESH(NM)
   DO ICF=1,MESHES(NM)%N_CUTFACE_MESH
      IF (CUT_FACE(ICF)%STATUS /= IBM_GASPHASE) CYCLE
      I     =CUT_FACE(ICF)%IJK(IAXIS)
      J     =CUT_FACE(ICF)%IJK(JAXIS)
      K     =CUT_FACE(ICF)%IJK(KAXIS)
      X1AXIS=CUT_FACE(ICF)%IJK(KAXIS+1)
      CF_STATUS = IBM_GASPHASE
      SELECT CASE(X1AXIS)
      CASE(IAXIS)
         IF ( SOLID(CELL_INDEX(I,J,K)) .AND. SOLID(CELL_INDEX(I+1,J,K)) ) CF_STATUS = IBM_SOLID
      CASE(JAXIS)
         IF ( SOLID(CELL_INDEX(I,J,K)) .AND. SOLID(CELL_INDEX(I,J+1,K)) ) CF_STATUS = IBM_SOLID
      CASE(KAXIS)
         IF ( SOLID(CELL_INDEX(I,J,K)) .AND. SOLID(CELL_INDEX(I,J,K+1)) ) CF_STATUS = IBM_SOLID
      END SELECT
      CUT_FACE(ICF)%STATUS = CF_STATUS
   ENDDO
ENDDO

RETURN

CONTAINS

SUBROUTINE GET_ICC2_JCC2(ICC,IFACE,INXT,JNXT,KNXT,ICC2,JCC2)
INTEGER, INTENT(IN) :: ICC,IFACE,INXT,JNXT,KNXT
INTEGER, INTENT(OUT):: ICC2, JCC2

INTEGER :: IFC, IFACE2
ICC2=CCVAR(INXT,JNXT,KNXT,IBM_IDCC); IF (ICC2<=0) RETURN
DO JCC2=1,CUT_CELL(ICC2)%NCELL
   ! Loop faces and test:
   DO IFC=1,CUT_CELL(ICC2)%CCELEM(1,JCC2)
      IFACE2 = CUT_CELL(ICC2)%CCELEM(IFC+1,JCC2)
      ! If face type in face_list is not IBM_FTYPE_RGGAS, drop:
      IF(CUT_CELL(ICC2)%FACE_LIST(1,IFACE2) /= IBM_FTYPE_RGGAS) CYCLE
      ! Does X1AXIS match and LOWHIGH are different?
      IF(CUT_CELL(ICC2)%FACE_LIST(3,IFACE2) /= CUT_CELL(ICC)%FACE_LIST(3,IFACE)) CYCLE ! X1AXIS is different.
      IF(ABS(CUT_CELL(ICC2)%FACE_LIST(2,IFACE2)-CUT_CELL(ICC)%FACE_LIST(3,IFACE)) < 1) CYCLE ! Same LOWHIGH.
      ! Found the cut-cell ICC2,JCC2 on the other side of IFACE for cut-cell ICC,JCC.
      RETURN
   ENDDO
ENDDO
JCC2=0
RETURN
END SUBROUTINE GET_ICC2_JCC2

END SUBROUTINE GET_MATRIX_INDEXES_Z

END MODULE CC_SCALARS_IBM
