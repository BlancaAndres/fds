MODULE FIRE

! Compute combustion

USE PRECISION_PARAMETERS
USE GLOBAL_CONSTANTS
USE MESH_POINTERS
USE COMP_FUNCTIONS, ONLY: CURRENT_TIME

IMPLICIT NONE

PRIVATE

PUBLIC COMBUSTION

CONTAINS

SUBROUTINE COMBUSTION(T,DT,NM)

INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN) :: T,DT
REAL(EB) :: TNOW

IF (EVACUATION_ONLY(NM)) RETURN
IF (INIT_HRRPUV) RETURN

TNOW=CURRENT_TIME()

CALL POINT_TO_MESH(NM)

! Call combustion ODE solver

CALL COMBUSTION_GENERAL(T,DT)

T_USED(10)=T_USED(10)+CURRENT_TIME()-TNOW

! Combustion in cut-cells:
! Time used for combustion in cut-cells is added to GEOM timing T_USED(14) in CCREGION_COMBUSTION.

IF (CC_IBM) CALL CCREGION_COMBUSTION(T,DT,NM)

END SUBROUTINE COMBUSTION


SUBROUTINE COMBUSTION_GENERAL(T,DT)

! Generic combustion routine for multi-step reactions

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL,GET_SPECIFIC_HEAT,GET_MOLECULAR_WEIGHT, &
                              GET_SENSIBLE_ENTHALPY_Z,IS_REALIZABLE,LES_FILTER_WIDTH_FUNCTION
USE COMPLEX_GEOMETRY, ONLY : IBM_CGSC, IBM_GASPHASE
INTEGER :: I,J,K,NS,NR,II,JJ,KK,IIG,JJG,KKG,IW,N,CHEM_SUBIT_TMP
REAL(EB), INTENT(IN) :: T,DT
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),DZZ(1:N_TRACKED_SPECIES),CP,H_S_N,&
            REAC_SOURCE_TERM_TMP(N_TRACKED_SPECIES),Q_REAC_TMP(N_REACTIONS),RSUM_LOC
LOGICAL :: Q_EXISTS
REAL(EB), POINTER, DIMENSION(:,:,:) :: AIT_P=>NULL()
TYPE (REACTION_TYPE), POINTER :: RN
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM
LOGICAL :: DO_REACTION,REALIZABLE

Q          = 0._EB
Q_EXISTS   = .FALSE.

CHI_R = 0._EB
IF (REAC_SOURCE_CHECK) Q_REAC=0._EB

AIT_P => WORK1
AIT_P = 0._EB
IF (REIGNITION_MODEL) AIT_P = AIT

DO K=1,KBAR
   DO J=1,JBAR
      ILOOP: DO I=1,IBAR
         ! Check to see if a reaction is possible
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ILOOP
         IF (CC_IBM) THEN
            IF (CCVAR(I,J,K,IBM_CGSC) /= IBM_GASPHASE) CYCLE ILOOP
         ENDIF
         ZZ_GET = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         IF (CHECK_REALIZABILITY) THEN
            REALIZABLE=IS_REALIZABLE(ZZ_GET)
            IF (.NOT.REALIZABLE) THEN
               WRITE(LU_ERR,*) I,J,K
               WRITE(LU_ERR,*) ZZ_GET
               WRITE(LU_ERR,*) SUM(ZZ_GET)
               WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions input to COMBUSTION_MODEL'
               STOP_STATUS=REALIZABILITY_STOP
            ENDIF
         ENDIF
         CALL CHECK_REACTION
         IF (.NOT.DO_REACTION) CYCLE ILOOP ! Check whether any reactions are possible.
         DZZ = ZZ_GET ! store old ZZ for divergence term
         !***************************************************************************************
         ! Call combustion integration routine for Cartesian cell (I,J,K)
         CALL COMBUSTION_MODEL( T,DT,ZZ_GET,Q(I,J,K),MIX_TIME(I,J,K),CHI_R(I,J,K),&
                                CHEM_SUBIT_TMP,REAC_SOURCE_TERM_TMP,Q_REAC_TMP,&
                                TMP(I,J,K),RHO(I,J,K),MU(I,J,K),&
                                AIT_P(I,J,K),&
                                LES_FILTER_WIDTH_FUNCTION(DX(I),DY(J),DZ(K)),DX(I)*DY(J)*DZ(K) )
         !***************************************************************************************
         IF (OUTPUT_CHEM_IT) CHEM_SUBIT(I,J,K) = CHEM_SUBIT_TMP
         IF (REAC_SOURCE_CHECK) THEN ! Store special diagnostic quantities
            REAC_SOURCE_TERM(I,J,K,:) = REAC_SOURCE_TERM_TMP
            Q_REAC(I,J,K,:) = Q_REAC_TMP
         ENDIF
         IF (CHECK_REALIZABILITY) THEN
            REALIZABLE=IS_REALIZABLE(ZZ_GET)
            IF (.NOT.REALIZABLE) THEN
               WRITE(LU_ERR,*) ZZ_GET,SUM(ZZ_GET)
               WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions after COMBUSTION_MODEL'
               STOP_STATUS=REALIZABILITY_STOP
            ENDIF
         ENDIF
         DZZ = ZZ_GET - DZZ
         ! Update RSUM and ZZ
         DZZ_IF: IF ( ANY(ABS(DZZ) > TWO_EPSILON_EB) ) THEN
            IF (ABS(Q(I,J,K)) > TWO_EPSILON_EB) Q_EXISTS = .TRUE.
               ! Divergence term
               CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,TMP(I,J,K))
               CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,RSUM_LOC)
               DO N=1,N_TRACKED_SPECIES
                  SM => SPECIES_MIXTURE(N)
                  CALL GET_SENSIBLE_ENTHALPY_Z(N,TMP(I,J,K),H_S_N)
                  D_SOURCE(I,J,K) = D_SOURCE(I,J,K) + ( SM%RCON/RSUM_LOC - H_S_N/(CP*TMP(I,J,K)) )*DZZ(N)/DT
                  M_DOT_PPP(I,J,K,N) = M_DOT_PPP(I,J,K,N) + RHO(I,J,K)*DZZ(N)/DT
               ENDDO
         ENDIF DZZ_IF
      ENDDO ILOOP
   ENDDO
ENDDO

IF (.NOT.Q_EXISTS) RETURN

! Set Q in the ghost cell, just for better visualization.

DO IW=1,N_EXTERNAL_WALL_CELLS
   IF (WALL(IW)%BOUNDARY_TYPE/=INTERPOLATED_BOUNDARY .AND. WALL(IW)%BOUNDARY_TYPE/=OPEN_BOUNDARY) CYCLE
   II  = WALL(IW)%ONE_D%II
   JJ  = WALL(IW)%ONE_D%JJ
   KK  = WALL(IW)%ONE_D%KK
   IIG = WALL(IW)%ONE_D%IIG
   JJG = WALL(IW)%ONE_D%JJG
   KKG = WALL(IW)%ONE_D%KKG
   Q(II,JJ,KK) = Q(IIG,JJG,KKG)
ENDDO


CONTAINS


SUBROUTINE CHECK_REACTION

! Check whether any reactions are possible.

LOGICAL :: REACTANTS_PRESENT

DO_REACTION = .FALSE.
REACTION_LOOP: DO NR=1,N_REACTIONS
   RN=>REACTION(NR)
   REACTANTS_PRESENT = .TRUE.
   DO NS=1,N_TRACKED_SPECIES
      IF ( RN%NU(NS) < -TWO_EPSILON_EB .AND. ZZ_GET(NS) < ZZ_MIN_GLOBAL ) THEN
         REACTANTS_PRESENT = .FALSE.
         EXIT
      ENDIF
   ENDDO
   DO_REACTION = REACTANTS_PRESENT
   IF (DO_REACTION) EXIT REACTION_LOOP
ENDDO REACTION_LOOP

END SUBROUTINE CHECK_REACTION

END SUBROUTINE COMBUSTION_GENERAL


SUBROUTINE COMBUSTION_MODEL(T,DT,ZZ_GET,Q_OUT,MIX_TIME_OUT,CHI_R_OUT,CHEM_SUBIT_OUT,REAC_SOURCE_TERM_OUT,Q_REAC_OUT,&
                            TMP_IN,RHO_IN,MU_IN,AIT_IN,DELTA,CELL_VOLUME)
USE COMP_FUNCTIONS, ONLY: SHUTDOWN
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
USE PHYSICAL_FUNCTIONS, ONLY: GET_AVERAGE_SPECIFIC_HEAT,GET_SPECIFIC_GAS_CONSTANT,GET_ENTHALPY
REAL(EB), INTENT(IN) :: T,DT,TMP_IN,RHO_IN,MU_IN,AIT_IN,DELTA,CELL_VOLUME
REAL(EB), INTENT(OUT) :: Q_OUT,MIX_TIME_OUT,CHI_R_OUT,REAC_SOURCE_TERM_OUT(N_TRACKED_SPECIES),Q_REAC_OUT(N_REACTIONS)
INTEGER, INTENT(OUT) :: CHEM_SUBIT_OUT
REAL(EB), INTENT(INOUT) :: ZZ_GET(1:N_TRACKED_SPECIES)
REAL(EB) :: ERR_EST,ERR_TOL,A1(1:N_TRACKED_SPECIES),A2(1:N_TRACKED_SPECIES),A4(1:N_TRACKED_SPECIES),ZETA,ZETA_0,&
            DT_SUB,DT_SUB_NEW,DT_ITER,ZZ_STORE(1:N_TRACKED_SPECIES,1:4),TV(1:3,1:N_TRACKED_SPECIES),CELL_MASS,&
            ZZ_DIFF(1:3,1:N_TRACKED_SPECIES),ZZ_MIXED(1:N_TRACKED_SPECIES),ZZ_UNMIXED(1:N_TRACKED_SPECIES),&
            ZZ_MIXED_NEW(1:N_TRACKED_SPECIES),TAU_D,TAU_G,TAU_U,TAU_MIX,TMP_MIXED,TMP_UNMIXED,DT_SUB_MIN,RHO_HAT,&
            VEL_RMS,ZZ_0(1:N_TRACKED_SPECIES),&
            Q_REAC_SUB(1:N_REACTIONS),Q_REAC_1(1:N_REACTIONS),Q_REAC_2(1:N_REACTIONS),Q_REAC_4(1:N_REACTIONS),&
            Q_REAC_SUM(1:N_REACTIONS),CHI_R_SUM,TIME_RAMP_FACTOR,&
            TOTAL_MIXED_MASS_1,TOTAL_MIXED_MASS_2,TOTAL_MIXED_MASS_4,TOTAL_MIXED_MASS,&
            ZETA_1,ZETA_2,ZETA_4,AIT_LOC,D_F
INTEGER :: NR,NS,ITER,TVI,RICH_ITER,TIME_ITER,RICH_ITER_MAX
INTEGER, PARAMETER :: TV_ITER_MIN=5
LOGICAL :: TV_FLUCT(1:N_TRACKED_SPECIES),EXTINCT
TYPE(REACTION_TYPE), POINTER :: RN=>NULL()
REAL(EB), PARAMETER :: C_U = 0.4_EB*0.1_EB*SQRT(1.5_EB) ! C_U*C_DEARDORFF/SQRT(2/3)

ZZ_0 = ZZ_GET
EXTINCT = .FALSE.

VEL_RMS = 0._EB
IF (FIXED_MIX_TIME>0._EB) THEN
   MIX_TIME_OUT=FIXED_MIX_TIME
ELSE
   D_F=0._EB
   DO NR =1,N_REACTIONS
      RN => REACTION(NR)
      D_F = MAX(D_F,D_Z(MIN(4999,NINT(TMP_IN)),RN%FUEL_SMIX_INDEX))
   ENDDO
   TAU_D = DELTA**2/MAX(D_F,TWO_EPSILON_EB)                         ! FDS Tech Guide (5.14)
   SELECT CASE(SIM_MODE)
      CASE DEFAULT
         TAU_U = C_U*RHO_IN*DELTA**2/MAX(MU_IN,TWO_EPSILON_EB)         ! FDS Tech Guide (5.15)
         TAU_G = SQRT(2._EB*DELTA/(GRAV+1.E-10_EB))                    ! FDS Tech Guide (5.16)
         MIX_TIME_OUT= MAX(TAU_CHEM,MIN(TAU_D,TAU_U,TAU_G,TAU_FLAME))  ! FDS Tech Guide (5.13)
         VEL_RMS = SQRT(TWTH)*MU_IN/(RHO_IN*C_DEARDORFF*DELTA)
      CASE (DNS_MODE)
         MIX_TIME_OUT= MAX(TAU_CHEM,TAU_D)
   END SELECT
ENDIF

ZETA_0 = INITIAL_UNMIXED_FRACTION
CELL_MASS = RHO_IN*CELL_VOLUME

IF (REIGNITION_MODEL) THEN
   AIT_LOC = AIT_IN
ELSE
   AIT_LOC = 1.E20_EB
ENDIF

DT_SUB_MIN = DT/REAL(MAX_CHEMISTRY_SUBSTEPS,EB)

ZZ_STORE(:,:) = 0._EB
Q_OUT = 0._EB
ITER= 0
DT_ITER = 0._EB
CHI_R_OUT = 0._EB
CHEM_SUBIT_OUT = 0
REAC_SOURCE_TERM_OUT(:) = 0._EB
Q_REAC_OUT(:) = 0._EB
Q_REAC_SUM(:) = 0._EB
IF (N_FIXED_CHEMISTRY_SUBSTEPS>0) THEN
   DT_SUB = DT/REAL(N_FIXED_CHEMISTRY_SUBSTEPS,EB)
   DT_SUB_NEW = DT_SUB
   RICH_ITER_MAX = 1
ELSE
   DT_SUB = DT
   DT_SUB_NEW = DT
   RICH_ITER_MAX = 5
ENDIF
ZZ_UNMIXED = ZZ_GET
ZZ_MIXED = ZZ_GET
A1 = ZZ_GET
A2 = ZZ_GET
A4 = ZZ_GET

ZETA = ZETA_0
RHO_HAT = RHO_IN
TMP_MIXED = TMP_IN
TMP_UNMIXED = TMP_IN
TAU_MIX = MIX_TIME_OUT

INTEGRATION_LOOP: DO TIME_ITER = 1,MAX_CHEMISTRY_SUBSTEPS

   IF (SUPPRESSION) CALL CHECK_AUTO_IGNITION(EXTINCT,TMP_MIXED,AIT_LOC,T)
   IF (EXTINCT) EXIT INTEGRATION_LOOP

   INTEGRATOR_SELECT: SELECT CASE (COMBUSTION_ODE_SOLVER)

      CASE (EXPLICIT_EULER) ! Simple chemistry

         ! May be used with N_FIXED_CHEMISTRY_SUBSTEPS, but default mode is DT_SUB=DT for fast chemistry

         CALL FIRE_FORWARD_EULER(ZZ_MIXED_NEW,ZZ_MIXED,ZZ_UNMIXED,ZETA,ZETA_0,DT_SUB,TMP_MIXED,TMP_UNMIXED,RHO_HAT,&
                                 CELL_MASS,TAU_MIX,Q_REAC_SUB,TIME_ITER,TOTAL_MIXED_MASS)
         ZETA_0 = ZETA
         ZZ_MIXED = ZZ_MIXED_NEW

      CASE (RK2_RICHARDSON) ! Finite-rate (or mixed finite-rate/fast) chemistry

         ! May be used with N_FIXED_CHEMISTRY_SUBSTEPS, but default mode is to use error estimator and variable DT_SUB

         ERR_TOL = RICHARDSON_ERROR_TOLERANCE
         RICH_EX_LOOP: DO RICH_ITER = 1,RICH_ITER_MAX

            DT_SUB = MIN(DT_SUB_NEW,DT-DT_ITER)

            ! FDS Tech Guide (E.3), (E.4), (E.5)
            CALL FIRE_RK2(A1,ZZ_MIXED,ZZ_UNMIXED,ZETA_1,ZETA_0,DT_SUB,1,TMP_MIXED,TMP_UNMIXED,RHO_HAT,CELL_MASS,TAU_MIX,&
                        Q_REAC_1,TIME_ITER,TOTAL_MIXED_MASS_1)
            CALL FIRE_RK2(A2,ZZ_MIXED,ZZ_UNMIXED,ZETA_2,ZETA_0,DT_SUB,2,TMP_MIXED,TMP_UNMIXED,RHO_HAT,CELL_MASS,TAU_MIX,&
                        Q_REAC_2,TIME_ITER,TOTAL_MIXED_MASS_2)
            CALL FIRE_RK2(A4,ZZ_MIXED,ZZ_UNMIXED,ZETA_4,ZETA_0,DT_SUB,4,TMP_MIXED,TMP_UNMIXED,RHO_HAT,CELL_MASS,TAU_MIX,&
                        Q_REAC_4,TIME_ITER,TOTAL_MIXED_MASS_4)

            ! Species Error Analysis
            ERR_EST = MAXVAL(ABS((4._EB*A4-5._EB*A2+A1)))/45._EB ! FDS Tech Guide (E.8)

            IF (N_FIXED_CHEMISTRY_SUBSTEPS<0) THEN
               DT_SUB_NEW = MIN(MAX(DT_SUB*(ERR_TOL/(ERR_EST+TWO_EPSILON_EB))**(0.25_EB),DT_SUB_MIN),DT-DT_ITER) ! (E.9)
               IF (ERR_EST<ERR_TOL) EXIT RICH_EX_LOOP
            ENDIF

         ENDDO RICH_EX_LOOP

         ZZ_MIXED   = (4._EB*A4-A2)*ONTH ! FDS Tech Guide (E.7)
         Q_REAC_SUB = (4._EB*Q_REAC_4-Q_REAC_2)*ONTH
         ZETA       = (4._EB*ZETA_4-ZETA_2)*ONTH
         ZETA_0     = ZETA

   END SELECT INTEGRATOR_SELECT

   ZZ_GET = ZETA*ZZ_UNMIXED + (1._EB-ZETA)*ZZ_MIXED ! FDS Tech Guide (5.19)

   DT_ITER = DT_ITER + DT_SUB
   ITER = ITER + 1
   IF (OUTPUT_CHEM_IT) CHEM_SUBIT_OUT = ITER

   Q_REAC_SUM = Q_REAC_SUM + Q_REAC_SUB

   ! Total Variation (TV) scheme (accelerates integration for finite-rate equilibrium calculations)
   ! See FDS Tech Guide Appendix E

   IF (COMBUSTION_ODE_SOLVER==RK2_RICHARDSON .AND. N_REACTIONS>1) THEN
      DO NS = 1,N_TRACKED_SPECIES
         DO TVI = 1,3
            ZZ_STORE(NS,TVI)=ZZ_STORE(NS,TVI+1)
         ENDDO
         ZZ_STORE(NS,4) = ZZ_GET(NS)
      ENDDO
      TV_FLUCT(:) = .FALSE.
      IF (ITER >= TV_ITER_MIN) THEN
         SPECIES_LOOP_TV: DO NS = 1,N_TRACKED_SPECIES
            DO TVI = 1,3
               TV(TVI,NS) = ABS(ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI))
               ZZ_DIFF(TVI,NS) = ZZ_STORE(NS,TVI+1)-ZZ_STORE(NS,TVI)
            ENDDO
            IF (SUM(TV(:,NS)) < ERR_TOL .OR. SUM(TV(:,NS)) >= ABS(2.9_EB*SUM(ZZ_DIFF(:,NS)))) THEN ! FDS Tech Guide (E.10)
               TV_FLUCT(NS) = .TRUE.
            ENDIF
            IF (ALL(TV_FLUCT)) EXIT INTEGRATION_LOOP
         ENDDO SPECIES_LOOP_TV
      ENDIF
   ENDIF

   IF ( DT_ITER > (DT+TWO_EPSILON_EB) ) CALL SHUTDOWN('ERROR: DT_ITER > DT in COMBUSTION_MODEL')
   IF ( DT_ITER > (DT-TWO_EPSILON_EB) ) EXIT INTEGRATION_LOOP

ENDDO INTEGRATION_LOOP

! Compute heat release rate

Q_OUT = -RHO_IN*SUM(SPECIES_MIXTURE%H_F*(ZZ_GET-ZZ_0))/DT ! FDS Tech Guide (5.44)

! Extinction model

IF (SUPPRESSION) THEN
   SELECT CASE(EXTINCT_MOD)
      CASE(EXTINCTION_1); CALL EXTINCT_1(EXTINCT,ZZ_0,TMP_IN)
      CASE(EXTINCTION_2); CALL EXTINCT_2(EXTINCT,ZZ_0,ZZ_MIXED,TMP_IN)
   END SELECT
ENDIF

IF (EXTINCT) THEN
   ZZ_GET = ZZ_0
   ZZ_STORE(:,:) = 0._EB
   Q_OUT = 0._EB
   CHI_R_OUT = 0._EB
   CHEM_SUBIT_OUT = 0
   REAC_SOURCE_TERM_OUT(:) = 0._EB
   Q_REAC_OUT(:) = 0._EB
   Q_REAC_SUM(:) = 0._EB
ENDIF

! Reaction rate-weighted radiative fraction

IF (SUM(Q_REAC_SUM)>TWO_EPSILON_EB) THEN
   CHI_R_SUM=0._EB
   DO NR=1,N_REACTIONS
      RN=>REACTION(NR)
      TIME_RAMP_FACTOR = EVALUATE_RAMP(T,0._EB,RN%RAMP_CHI_R_INDEX)
      CHI_R_SUM = CHI_R_SUM + Q_REAC_SUM(NR)*RN%CHI_R*TIME_RAMP_FACTOR
   ENDDO
   CHI_R_OUT = CHI_R_SUM/(SUM(Q_REAC_SUM))
ENDIF
CHI_R_OUT = MAX(CHI_R_MIN,MIN(CHI_R_MAX,CHI_R_OUT))

! Store special diagnostic quantities

IF (REAC_SOURCE_CHECK) THEN
   REAC_SOURCE_TERM_OUT = RHO_IN*(ZZ_GET-ZZ_0)/DT
   Q_REAC_OUT = Q_REAC_SUM/CELL_VOLUME/DT
ENDIF

END SUBROUTINE COMBUSTION_MODEL


SUBROUTINE CHECK_AUTO_IGNITION(EXTINCT,TMP_MIXED,AIT_IN,T)
USE MATH_FUNCTIONS, ONLY: EVALUATE_RAMP
LOGICAL, INTENT(INOUT) :: EXTINCT
REAL(EB), INTENT(IN) :: TMP_MIXED,AIT_IN,T
INTEGER :: NR
REAL(EB):: AIT_LOC,TIME_RAMP_FACTOR
TYPE(REACTION_TYPE),POINTER :: RN=>NULL()

EXTINCT = .TRUE.

SELECT CASE (EXTINCT_MOD)
   CASE DEFAULT
      ! if ANY reaction exceeds AIT, allow all reactions and proceed to EXTINCTION MODEL
      ! note: here we include finite-rate reactions, else combustion model will exit
      ! integration loop (as presently coded)
      REACTION_LOOP: DO NR=1,N_REACTIONS
         RN => REACTION(NR)
         IF (AIT_IN < 1.E10_EB) THEN
            AIT_LOC = AIT_IN
         ELSE
            AIT_LOC = RN%AUTO_IGNITION_TEMPERATURE
         ENDIF
         TIME_RAMP_FACTOR = EVALUATE_RAMP(T,0._EB,RN%RAMP_AIT_INDEX)
         IF ( TMP_MIXED > AIT_LOC*TIME_RAMP_FACTOR ) THEN
            EXTINCT = .FALSE.
            EXIT REACTION_LOOP
         ENDIF
      ENDDO REACTION_LOOP

END SELECT

END SUBROUTINE CHECK_AUTO_IGNITION


SUBROUTINE EXTINCT_1(EXTINCT,ZZ_IN,TMP_IN)

! Mowrer model, linear relationship between gas temperature and limiting oxygen concentration.

USE PHYSICAL_FUNCTIONS, ONLY: GET_MASS_FRACTION
REAL(EB), INTENT(IN) :: TMP_IN,ZZ_IN(1:N_TRACKED_SPECIES)
LOGICAL, INTENT(INOUT) :: EXTINCT
REAL(EB) :: Y_O2,Y_O2_LIM

EXTINCT = .FALSE.
CALL GET_MASS_FRACTION(ZZ_IN,O2_INDEX,Y_O2)
Y_O2_LIM = REACTION(1)%Y_O2_MIN*(REACTION(1)%CRIT_FLAME_TMP-TMP_IN)/(REACTION(1)%CRIT_FLAME_TMP-TMPA)
IF (Y_O2 < Y_O2_LIM) EXTINCT = .TRUE.

END SUBROUTINE EXTINCT_1


SUBROUTINE EXTINCT_2(EXTINCT,ZZ_0_IN,ZZ_IN,TMP_IN)

! Default model, FDS Tech Guide, Section 5.3

USE PHYSICAL_FUNCTIONS, ONLY: GET_ENTHALPY
REAL(EB),INTENT(IN) :: TMP_IN,ZZ_0_IN(1:N_TRACKED_SPECIES),ZZ_IN(1:N_TRACKED_SPECIES)
LOGICAL, INTENT(INOUT) :: EXTINCT
REAL(EB) :: ZZ_HAT_0(1:N_TRACKED_SPECIES),ZZ_HAT(1:N_TRACKED_SPECIES),H_0,H_CRIT,PHI_TILDE
INTEGER :: NS
TYPE(REACTION_TYPE), POINTER :: R1=>NULL()

IF (.NOT.REACTION(1)%FAST_CHEMISTRY) RETURN
R1 => REACTION(1)
PHI_TILDE = (ZZ_0_IN(R1%AIR_SMIX_INDEX) - ZZ_IN(R1%AIR_SMIX_INDEX)) / ZZ_0_IN(R1%AIR_SMIX_INDEX)  ! FDS Tech Guide (5.45)

! Define the modified pre and post mixtures (ZZ_HAT_0 and ZZ_HAT) in which excess air and products are excluded.

DO NS=1,N_TRACKED_SPECIES
   IF (NS==R1%FUEL_SMIX_INDEX) THEN
      ZZ_HAT_0(NS) = ZZ_0_IN(NS)
      ZZ_HAT(NS)   = ZZ_IN(NS)
   ELSEIF (NS==R1%AIR_SMIX_INDEX) THEN
      ZZ_HAT_0(NS) = PHI_TILDE * ZZ_0_IN(NS)
      ZZ_HAT(NS)   = 0._EB
   ELSE  ! Products
      ZZ_HAT_0(NS) = PHI_TILDE * ZZ_0_IN(NS)
      ZZ_HAT(NS)   = (PHI_TILDE-1._EB)*ZZ_0_IN(NS) + ZZ_IN(NS)
   ENDIF
ENDDO

! Normalize the modified pre and post mixtures

ZZ_HAT_0 = ZZ_HAT_0/SUM(ZZ_HAT_0)
ZZ_HAT = ZZ_HAT/SUM(ZZ_HAT)

! See if enough energy is released to raise the fuel and required "air" temperatures above the critical flame temp.

CALL GET_ENTHALPY(ZZ_HAT_0,H_0,TMP_IN) ! H of reactants participating in reaction (includes chemical enthalpy)
CALL GET_ENTHALPY(ZZ_HAT,H_CRIT,R1%CRIT_FLAME_TMP) ! H of products at the critical flame temperature
IF (H_0 < H_CRIT) EXTINCT = .TRUE. ! FDS Tech Guide (5.46)

END SUBROUTINE EXTINCT_2


SUBROUTINE FIRE_FORWARD_EULER(ZZ_OUT,ZZ_IN,ZZ_UNMIXED,ZETA_OUT,ZETA_IN,DT_LOC,TMP_MIXED,TMP_UNMIXED,RHO_HAT,CELL_MASS,TAU_MIX,&
                              Q_REAC_LOC,SUB_IT,TOTAL_MIXED_MASS)
USE PHYSICAL_FUNCTIONS, ONLY: GET_REALIZABLE_MF,GET_AVERAGE_SPECIFIC_HEAT
REAL(EB), INTENT(IN) :: ZZ_IN(1:N_TRACKED_SPECIES),ZETA_IN,DT_LOC,RHO_HAT,ZZ_UNMIXED(1:N_TRACKED_SPECIES),CELL_MASS,TAU_MIX,&
                        TMP_UNMIXED
INTEGER, INTENT(IN) :: SUB_IT
REAL(EB), INTENT(OUT) :: ZZ_OUT(1:N_TRACKED_SPECIES),ZETA_OUT,Q_REAC_LOC(1:N_REACTIONS),TOTAL_MIXED_MASS
REAL(EB), INTENT(INOUT) :: TMP_MIXED
REAL(EB) :: ZZ_0(1:N_TRACKED_SPECIES),ZZ_NEW(1:N_TRACKED_SPECIES),DZZ(1:N_TRACKED_SPECIES),&
            MIXED_MASS(1:N_TRACKED_SPECIES),MIXED_MASS_0(1:N_TRACKED_SPECIES),&
            Q_REAC_OUT(1:N_REACTIONS),TOTAL_MIXED_MASS_0
INTEGER, PARAMETER :: INFINITELY_FAST=1,FINITE_RATE=2
INTEGER :: PTY

! Determine initial state of mixed reactor zone

TOTAL_MIXED_MASS_0  = (1._EB-ZETA_IN)*CELL_MASS
MIXED_MASS_0  = ZZ_IN*TOTAL_MIXED_MASS_0

! Mixing step

ZETA_OUT = MAX(0._EB,ZETA_IN*EXP(-DT_LOC/TAU_MIX)) ! FDS Tech Guide (5.18)
TOTAL_MIXED_MASS = (1._EB-ZETA_OUT)*CELL_MASS      ! FDS Tech Guide (5.23)
MIXED_MASS = MAX(0._EB,MIXED_MASS_0 - (ZETA_OUT - ZETA_IN)*ZZ_UNMIXED*CELL_MASS) ! FDS Tech Guide (5.26)
ZZ_0 = MIXED_MASS/MAX(TOTAL_MIXED_MASS,TWO_EPSILON_EB) ! FDS Tech Guide (5.27)

! Enforce realizability on mass fractions

CALL GET_REALIZABLE_MF(ZZ_0)

! Placeholder for TEMPERATURE_DEPENDENT_REACTION

TMP_MIXED = TMP_UNMIXED

! Do the infinite rate (fast chemistry) reactions either in parallel (PRIORITY=1 for all) or serially (PRIORITY>1 for some)

Q_REAC_LOC(:) = 0._EB
IF (ANY(REACTION(:)%FAST_CHEMISTRY)) THEN
   DO PTY = 1,MAX_PRIORITY
      CALL REACTION_RATE(DZZ,ZZ_0,DT_LOC,RHO_HAT,TMP_MIXED,INFINITELY_FAST,Q_REAC_OUT,SUB_IT,PRIORITY=PTY)
      ZZ_NEW = ZZ_0 + DZZ
      ZZ_0 = ZZ_NEW
      Q_REAC_LOC = Q_REAC_LOC + Q_REAC_OUT*TOTAL_MIXED_MASS
   ENDDO
ENDIF

! Do all finite rate reactions in parallel

IF (.NOT.ALL(REACTION(:)%FAST_CHEMISTRY)) THEN
   CALL REACTION_RATE(DZZ,ZZ_0,DT_LOC,RHO_HAT,TMP_MIXED,FINITE_RATE,Q_REAC_OUT,SUB_IT)
   ZZ_NEW = ZZ_0 + DZZ
   Q_REAC_LOC = Q_REAC_LOC + Q_REAC_OUT*TOTAL_MIXED_MASS
ENDIF

! Enforce realizability on mass fractions

CALL GET_REALIZABLE_MF(ZZ_NEW)

ZZ_OUT = ZZ_NEW

END SUBROUTINE FIRE_FORWARD_EULER


SUBROUTINE FIRE_RK2(ZZ_OUT,ZZ_IN,ZZ_UNMIXED,ZETA_OUT,ZETA_IN,DT_SUB,N_INC,TMP_MIXED,TMP_UNMIXED,RHO_HAT,CELL_MASS,TAU_MIX,&
                    Q_REAC_OUT,SUB_IT,TOTAL_MIXED_MASS_OUT)

! This function uses RK2 to integrate ZZ_O from t=0 to t=DT_SUB in increments of DT_LOC=DT_SUB/N_INC

REAL(EB), INTENT(IN) :: ZZ_IN(1:N_TRACKED_SPECIES),DT_SUB,ZETA_IN,RHO_HAT,ZZ_UNMIXED(1:N_TRACKED_SPECIES),CELL_MASS,&
                        TAU_MIX,TMP_UNMIXED
REAL(EB), INTENT(OUT) :: ZZ_OUT(1:N_TRACKED_SPECIES),ZETA_OUT,Q_REAC_OUT(1:N_REACTIONS),TOTAL_MIXED_MASS_OUT
REAL(EB), INTENT(INOUT) :: TMP_MIXED
INTEGER, INTENT(IN) :: N_INC,SUB_IT
REAL(EB) :: DT_LOC,ZZ_0(1:N_TRACKED_SPECIES),ZZ_1(1:N_TRACKED_SPECIES),ZZ_2(1:N_TRACKED_SPECIES),ZETA_0,ZETA_1,ZETA_2,&
            Q_REAC_1(1:N_REACTIONS),Q_REAC_2(1:N_REACTIONS),TOTAL_MIXED_MASS_0,TOTAL_MIXED_MASS_1,TOTAL_MIXED_MASS_2
INTEGER :: N

DT_LOC = DT_SUB/REAL(N_INC,EB)
ZZ_0 = ZZ_IN
ZETA_0 = ZETA_IN
Q_REAC_OUT(:) = 0._EB
TOTAL_MIXED_MASS_0 = (1._EB-ZETA_0)*CELL_MASS

DO N=1,N_INC

   CALL FIRE_FORWARD_EULER(ZZ_1,ZZ_0,ZZ_UNMIXED,ZETA_1,ZETA_0,DT_LOC,TMP_MIXED,TMP_UNMIXED,RHO_HAT,CELL_MASS,TAU_MIX,&
                           Q_REAC_1,SUB_IT,TOTAL_MIXED_MASS_1)

   CALL FIRE_FORWARD_EULER(ZZ_2,ZZ_1,ZZ_UNMIXED,ZETA_2,ZETA_1,DT_LOC,TMP_MIXED,TMP_UNMIXED,RHO_HAT,CELL_MASS,TAU_MIX,&
                           Q_REAC_2,SUB_IT,TOTAL_MIXED_MASS_2)

   IF (TOTAL_MIXED_MASS_2>TWO_EPSILON_EB) THEN
      ZZ_OUT = 0.5_EB*(ZZ_0*TOTAL_MIXED_MASS_0 + ZZ_2*TOTAL_MIXED_MASS_2)
      TOTAL_MIXED_MASS_OUT = SUM(ZZ_OUT)
      ZZ_OUT = ZZ_OUT/TOTAL_MIXED_MASS_OUT
   ELSE
      ZZ_OUT = ZZ_0
   ENDIF

   ZETA_OUT = MAX(0._EB,1._EB-TOTAL_MIXED_MASS_OUT/CELL_MASS)

   Q_REAC_OUT = Q_REAC_OUT + 0.5_EB*(Q_REAC_1+Q_REAC_2)

   ZZ_0 = ZZ_OUT
   ZETA_0 = ZETA_OUT
   TOTAL_MIXED_MASS_0 = TOTAL_MIXED_MASS_OUT
ENDDO

END SUBROUTINE FIRE_RK2


SUBROUTINE REACTION_RATE(DZZ,ZZ_0,DT_SUB,RHO_0,TMP_0,KINETICS,Q_REAC_OUT,SUB_IT,PRIORITY)

USE PHYSICAL_FUNCTIONS, ONLY : GET_MASS_FRACTION_ALL,GET_SPECIFIC_GAS_CONSTANT,GET_GIBBS_FREE_ENERGY,GET_MOLECULAR_WEIGHT
REAL(EB), INTENT(OUT) :: DZZ(1:N_TRACKED_SPECIES),Q_REAC_OUT(1:N_REACTIONS)
REAL(EB), INTENT(IN) :: ZZ_0(1:N_TRACKED_SPECIES),DT_SUB,RHO_0,TMP_0
INTEGER, INTENT(IN) :: KINETICS,SUB_IT
INTEGER, INTENT(IN), OPTIONAL :: PRIORITY
REAL(EB) :: DZ_F,YY_PRIMITIVE(1:N_SPECIES),DG_RXN,MW,MOLPCM3,DT_TMP(1:N_TRACKED_SPECIES),DT_MIN,DT_LOC,&
            ZZ_TMP(1:N_TRACKED_SPECIES),ZZ_NEW(1:N_TRACKED_SPECIES),Q_REAC_TMP(1:N_REACTIONS),AA
INTEGER :: I,NS,SUB_IT_USE,OUTER_IT
LOGICAL :: REACTANTS_PRESENT
INTEGER, PARAMETER :: INFINITELY_FAST=1,FINITE_RATE=2
TYPE(REACTION_TYPE), POINTER :: RN=>NULL()

ZZ_NEW = ZZ_0
Q_REAC_OUT = 0._EB
Q_REAC_TMP = 0._EB
SUB_IT_USE = SUB_IT ! keep this for debug

KINETICS_SELECT: SELECT CASE(KINETICS)

   CASE(INFINITELY_FAST)

      FAST_REAC_LOOP: DO OUTER_IT=1,N_REACTIONS
         ZZ_TMP = ZZ_NEW
         DZZ = 0._EB
         REACTANTS_PRESENT = .FALSE.
         REACTION_LOOP_1: DO I=1,N_REACTIONS
            RN => REACTION(I)
            IF (.NOT.RN%FAST_CHEMISTRY .OR. RN%PRIORITY/=PRIORITY) CYCLE REACTION_LOOP_1
            IF (RN%AIR_SMIX_INDEX > -1) THEN
               DZ_F = ZZ_TMP(RN%FUEL_SMIX_INDEX)*ZZ_TMP(RN%AIR_SMIX_INDEX) ! 2nd-order reaction
            ELSE
               DZ_F = ZZ_TMP(RN%FUEL_SMIX_INDEX) ! 1st-order
            ENDIF
            IF (DZ_F > TWO_EPSILON_EB) REACTANTS_PRESENT = .TRUE.
            AA = RN%A_PRIME_FAST * RHO_0**RN%RHO_EXPONENT_FAST
            DZZ = DZZ + AA * RN%NU_MW_O_MW_F * DZ_F
            Q_REAC_TMP(I) = RN%HEAT_OF_COMBUSTION * AA * DZ_F
         ENDDO REACTION_LOOP_1
         IF (REACTANTS_PRESENT) THEN
            DT_TMP = HUGE_EB
            DO NS = 1,N_TRACKED_SPECIES
               IF (DZZ(NS) < 0._EB) DT_TMP(NS) = -ZZ_TMP(NS)/DZZ(NS)
            ENDDO
            DT_MIN = MINVAL(DT_TMP)
            ZZ_NEW = ZZ_TMP + DZZ*DT_MIN
            Q_REAC_OUT = Q_REAC_OUT + Q_REAC_TMP*DT_MIN
         ELSE
            EXIT FAST_REAC_LOOP
         ENDIF
      ENDDO FAST_REAC_LOOP
      DZZ = ZZ_NEW - ZZ_0

   CASE(FINITE_RATE)

      DT_LOC = DT_SUB
      SLOW_REAC_LOOP: DO OUTER_IT=1,N_REACTIONS
         ZZ_TMP = ZZ_NEW
         DZZ = 0._EB
         REACTANTS_PRESENT = .FALSE.
         REACTION_LOOP_2: DO I=1,N_REACTIONS
            RN => REACTION(I)
            IF (RN%FAST_CHEMISTRY) CYCLE REACTION_LOOP_2
            IF (ZZ_TMP(RN%FUEL_SMIX_INDEX) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2
            IF (RN%AIR_SMIX_INDEX > -1) THEN
               IF (ZZ_TMP(RN%AIR_SMIX_INDEX) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2 ! no expected air
            ENDIF
            CALL GET_MASS_FRACTION_ALL(ZZ_TMP,YY_PRIMITIVE)
            DO NS=1,N_SPECIES
               IF(RN%N_S(NS) > -998._EB .AND. YY_PRIMITIVE(NS) < ZZ_MIN_GLOBAL) CYCLE REACTION_LOOP_2
            ENDDO
            DZ_F = RN%A_PRIME*RHO_0**RN%RHO_EXPONENT*TMP_0**RN%N_T*EXP(-RN%E/(R0*TMP_0)) ! dZ/dt, FDS Tech Guide, Eq. (5.38)
            DO NS=1,N_SPECIES
               IF(RN%N_S(NS) > -998._EB) DZ_F = YY_PRIMITIVE(NS)**RN%N_S(NS)*DZ_F
            ENDDO
            IF (RN%THIRD_BODY) THEN
               CALL GET_MOLECULAR_WEIGHT(ZZ_TMP,MW)
               MOLPCM3 = RHO_0/MW*0.001_EB ! mol/cm^3
               DZ_F = DZ_F * MOLPCM3
            ENDIF
            IF(RN%REVERSE) THEN ! compute equilibrium constant
               CALL GET_GIBBS_FREE_ENERGY(DG_RXN,RN%NU,TMP_0)
               RN%K = EXP(-DG_RXN/(R0*TMP_0))
               DZ_F = DZ_F/RN%K
            ENDIF
            IF (DZ_F > TWO_EPSILON_EB) REACTANTS_PRESENT = .TRUE.
            Q_REAC_TMP(I) = RN%HEAT_OF_COMBUSTION * DZ_F * DT_LOC ! Note: here DZ_F=dZ/dt, hence need DT_LOC
            DZZ = DZZ + RN%NU_MW_O_MW_F*DZ_F*DT_LOC
         ENDDO REACTION_LOOP_2
         IF (REACTANTS_PRESENT) THEN
            DT_TMP = HUGE_EB
            DO NS = 1,N_TRACKED_SPECIES
               IF (DZZ(NS) < 0._EB) DT_TMP(NS) = -ZZ_TMP(NS)/DZZ(NS)
            ENDDO
            ! Think of DT_MIN as the fraction of DT_LOC we can take and remain bounded.
            DT_MIN = MIN(1._EB,MINVAL(DT_TMP))
            DT_LOC = DT_LOC*(1._EB-DT_MIN)
            ZZ_NEW = ZZ_TMP + DZZ*DT_MIN
            Q_REAC_OUT = Q_REAC_OUT + Q_REAC_TMP*DT_MIN
            IF (DT_LOC<TWO_EPSILON_EB) EXIT SLOW_REAC_LOOP
         ELSE
            EXIT SLOW_REAC_LOOP
         ENDIF
      ENDDO SLOW_REAC_LOOP
      DZZ = ZZ_NEW - ZZ_0

END SELECT KINETICS_SELECT

END SUBROUTINE REACTION_RATE


! ---------------------------- CCREGION_COMBUSTION ------------------------------

SUBROUTINE CCREGION_COMBUSTION(T,DT,NM)

USE PHYSICAL_FUNCTIONS, ONLY: GET_SPECIFIC_GAS_CONSTANT,GET_MASS_FRACTION_ALL,GET_SPECIFIC_HEAT,GET_MOLECULAR_WEIGHT, &
                              GET_SENSIBLE_ENTHALPY_Z,IS_REALIZABLE,LES_FILTER_WIDTH_FUNCTION
USE COMPLEX_GEOMETRY, ONLY : IBM_CGSC,IBM_GASPHASE

REAL(EB), INTENT(IN) :: T, DT
INTEGER, INTENT(IN) :: NM

! Local Variables:
INTEGER  :: I,J,K,ICC,JCC,NCELL,NS,NR,N,CHEM_SUBIT_TMP
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),DZZ(1:N_TRACKED_SPECIES),CP,H_S_N,&
            REAC_SOURCE_TERM_TMP(N_TRACKED_SPECIES),Q_REAC_TMP(N_REACTIONS),VCELL,VCCELL
REAL(EB) :: AIT_P
LOGICAL  :: Q_EXISTS_CC
TYPE (REACTION_TYPE), POINTER :: RN
TYPE (SPECIES_MIXTURE_TYPE), POINTER :: SM
LOGICAL  :: DO_REACTION,REALIZABLE
LOGICAL :: Q_EXISTS
REAL(EB) :: TNOW

TNOW = CURRENT_TIME()

! Set to zero Reaction, Radiation sources of heat and thermodynamic div:
DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (CCVAR(I,J,K,IBM_CGSC) == IBM_GASPHASE) CYCLE
         Q(I,J,K) = 0._EB
         QR(I,J,K)= 0._EB
         CHI_R(I,J,K) = 0._EB
      ENDDO
   ENDDO
ENDDO

! Now do COMBUSTION_GENERAL for cut-cells.
Q_EXISTS_CC   = .FALSE.

IF (REAC_SOURCE_CHECK) THEN
   DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
      DO JCC=1,CUT_CELL(ICC)%NCELL
         CUT_CELL(ICC)%Q_REAC(:,JCC) = 0._EB
      ENDDO
   ENDDO
ENDIF

ICC_LOOP : DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
   I     = CUT_CELL(ICC)%IJK(IAXIS)
   J     = CUT_CELL(ICC)%IJK(JAXIS)
   K     = CUT_CELL(ICC)%IJK(KAXIS)

   VCELL = DX(I)*DY(J)*DZ(K)

   IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ICC_LOOP ! Cycle in case Cartesian cell inside OBSTS.

   NCELL = CUT_CELL(ICC)%NCELL
   JCC_LOOP : DO JCC=1,NCELL

      ! Drop if cut-cell is very small compared to Cartesian cells:
      IF ( ABS(CUT_CELL(ICC)%VOLUME(JCC)/VCELL) <  1.E-12_EB ) CYCLE JCC_LOOP

      CUT_CELL(ICC)%CHI_R(JCC)    = 0._EB
      ZZ_GET = CUT_CELL(ICC)%ZZ(1:N_TRACKED_SPECIES,JCC)

      AIT_P = 0._EB
      IF (REIGNITION_MODEL) AIT_P = CUT_CELL(ICC)%AIT(JCC)

      IF (CHECK_REALIZABILITY) THEN
         REALIZABLE=IS_REALIZABLE(ZZ_GET)
         IF (.NOT.REALIZABLE) THEN
            WRITE(LU_ERR,*) I,J,K
            WRITE(LU_ERR,*) ZZ_GET
            WRITE(LU_ERR,*) SUM(ZZ_GET)
            WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions input to COMBUSTION_MODEL'
            STOP_STATUS=REALIZABILITY_STOP
         ENDIF
      ENDIF
      CALL CCCHECK_REACTION
      IF (.NOT.DO_REACTION) CYCLE ICC_LOOP ! Check whether any reactions are possible.

      DZZ = ZZ_GET ! store old ZZ for divergence term
      !***************************************************************************************
      ! Call combustion integration routine for CUT_CELL(ICC)%XX(JCC)
      CALL COMBUSTION_MODEL( T,DT,ZZ_GET,CUT_CELL(ICC)%Q(JCC),CUT_CELL(ICC)%MIX_TIME(JCC),&
                             CUT_CELL(ICC)%CHI_R(JCC),&
                             CHEM_SUBIT_TMP,REAC_SOURCE_TERM_TMP,Q_REAC_TMP,&
                             CUT_CELL(ICC)%TMP(JCC),CUT_CELL(ICC)%RHO(JCC),MU(I,J,K),&
                             AIT_P,&
                             LES_FILTER_WIDTH_FUNCTION(DX(I),DY(J),DZ(K)),&
                             CUT_CELL(ICC)%VOLUME(JCC))
      !***************************************************************************************
      IF (REAC_SOURCE_CHECK) THEN ! Store special diagnostic quantities
          CUT_CELL(ICC)%REAC_SOURCE_TERM(1:N_TRACKED_SPECIES,JCC)=REAC_SOURCE_TERM_TMP(1:N_TRACKED_SPECIES)
          CUT_CELL(ICC)%Q_REAC(1:N_REACTIONS,JCC)=Q_REAC_TMP(1:N_REACTIONS)
      ENDIF

      IF (CHECK_REALIZABILITY) THEN
         REALIZABLE=IS_REALIZABLE(ZZ_GET)
         IF (.NOT.REALIZABLE) THEN
            WRITE(LU_ERR,*) ZZ_GET,SUM(ZZ_GET)
            WRITE(LU_ERR,*) 'ERROR: Unrealizable mass fractions after COMBUSTION_MODEL'
            STOP_STATUS=REALIZABILITY_STOP
         ENDIF
      ENDIF

      DZZ = ZZ_GET - DZZ

      ! Update RSUM and ZZ
      DZZ_IF: IF ( ANY(ABS(DZZ) > TWO_EPSILON_EB) ) THEN
         IF (ABS(CUT_CELL(ICC)%Q(JCC)) > TWO_EPSILON_EB) Q_EXISTS = .TRUE.
            ! Divergence term
            CALL GET_SPECIFIC_HEAT(ZZ_GET,CP,CUT_CELL(ICC)%TMP(JCC))
            CALL GET_SPECIFIC_GAS_CONSTANT(ZZ_GET,CUT_CELL(ICC)%RSUM(JCC))
            DO N=1,N_TRACKED_SPECIES
               SM => SPECIES_MIXTURE(N)
               CALL GET_SENSIBLE_ENTHALPY_Z(N,CUT_CELL(ICC)%TMP(JCC),H_S_N)
               CUT_CELL(ICC)%D_SOURCE(JCC) = CUT_CELL(ICC)%D_SOURCE(JCC) + &
               ( SM%RCON/CUT_CELL(ICC)%RSUM(JCC) - H_S_N/(CP*CUT_CELL(ICC)%TMP(JCC)) )*DZZ(N)/DT
               CUT_CELL(ICC)%M_DOT_PPP(N,JCC) = CUT_CELL(ICC)%M_DOT_PPP(N,JCC) + &
               CUT_CELL(ICC)%RHO(JCC)*DZZ(N)/DT
            ENDDO
      ENDIF DZZ_IF
   ENDDO JCC_LOOP
ENDDO ICC_LOOP

! This volume refactoring is needed for RADIATION_FVM (CHI_R, Q) and plotting slices:
DO ICC=1,MESHES(NM)%N_CUTCELL_MESH
   I     = CUT_CELL(ICC)%IJK(IAXIS)
   J     = CUT_CELL(ICC)%IJK(JAXIS)
   K     = CUT_CELL(ICC)%IJK(KAXIS)

   VCELL = DX(I)*DY(J)*DZ(K)

   IF (SOLID(CELL_INDEX(I,J,K))) CYCLE ! Cycle in case Cartesian cell inside OBSTS.

   NCELL = CUT_CELL(ICC)%NCELL
   DO JCC=1,NCELL
      Q(I,J,K) = Q(I,J,K)+CUT_CELL(ICC)%Q(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
      CHI_R(I,J,K) = CHI_R(I,J,K) + CUT_CELL(ICC)%CHI_R(JCC)*CUT_CELL(ICC)%Q(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
   ENDDO
   IF(ABS(Q(I,J,K)) > TWO_EPSILON_EB) THEN
      CHI_R(I,J,K) = CHI_R(I,J,K)/Q(I,J,K)
   ELSE
      CHI_R(I,J,K) = 0._EB
      DO JCC=1,NCELL
         CHI_R(I,J,K) = CHI_R(I,J,K) + CUT_CELL(ICC)%CHI_R(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
      ENDDO
      CHI_R(I,J,K) = CHI_R(I,J,K)/VCELL
   ENDIF
   Q(I,J,K) = Q(I,J,K)/VCELL

   ! Up to here in D_SOURCE(I,J,K), M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) we have contributions by particle evaporation.
   ! Add these contributions in corresponding cut-cells:
   VCCELL = SUM(CUT_CELL(ICC)%VOLUME(1:NCELL))
   DO JCC=1,NCELL
      CUT_CELL(ICC)%D_SOURCE(JCC) = CUT_CELL(ICC)%D_SOURCE(JCC) + D_SOURCE(I,J,K)*VCELL/VCCELL
      CUT_CELL(ICC)%M_DOT_PPP(1:N_TOTAL_SCALARS,JCC) = CUT_CELL(ICC)%M_DOT_PPP(1:N_TOTAL_SCALARS,JCC) + &
      M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS)*VCELL/VCCELL
   ENDDO

   ! Now Add back to D_SOURCE(I,J,K), M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) for regular slice plotting:
   D_SOURCE(I,J,K) = 0._EB; M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) = 0._EB
   DO JCC=1,NCELL
      D_SOURCE(I,J,K) = D_SOURCE(I,J,K) + CUT_CELL(ICC)%D_SOURCE(JCC)*CUT_CELL(ICC)%VOLUME(JCC)
      M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) = M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) + &
      CUT_CELL(ICC)%M_DOT_PPP(1:N_TOTAL_SCALARS,JCC)*CUT_CELL(ICC)%VOLUME(JCC)
   ENDDO
   D_SOURCE(I,J,K)=D_SOURCE(I,J,K)/VCELL
   M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS) = M_DOT_PPP(I,J,K,1:N_TOTAL_SCALARS)/VCELL
ENDDO

T_USED(14) = T_USED(14) + CURRENT_TIME() - TNOW
RETURN

CONTAINS

SUBROUTINE CCCHECK_REACTION

! Check whether any reactions are possible.

LOGICAL :: REACTANTS_PRESENT

DO_REACTION = .FALSE.
REACTION_LOOP: DO NR=1,N_REACTIONS
   RN=>REACTION(NR)
   REACTANTS_PRESENT = .TRUE.
   DO NS=1,N_TRACKED_SPECIES
      IF ( RN%NU(NS) < -TWO_EPSILON_EB .AND. ZZ_GET(NS) < ZZ_MIN_GLOBAL ) THEN
         REACTANTS_PRESENT = .FALSE.
         EXIT
      ENDIF
   ENDDO
   DO_REACTION = REACTANTS_PRESENT
   IF (DO_REACTION) EXIT REACTION_LOOP
ENDDO REACTION_LOOP

END SUBROUTINE CCCHECK_REACTION


END SUBROUTINE CCREGION_COMBUSTION

END MODULE FIRE
