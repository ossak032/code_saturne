!-------------------------------------------------------------------------------

! This file is part of Code_Saturne, a general-purpose CFD tool.
!
! Copyright (C) 1998-2014 EDF S.A.
!
! This program is free software; you can redistribute it and/or modify it under
! the terms of the GNU General Public License as published by the Free Software
! Foundation; either version 2 of the License, or (at your option) any later
! version.
!
! This program is distributed in the hope that it will be useful, but WITHOUT
! ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
! FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
! details.
!
! You should have received a copy of the GNU General Public License along with
! this program; if not, write to the Free Software Foundation, Inc., 51 Franklin
! Street, Fifth Floor, Boston, MA 02110-1301, USA.

!-------------------------------------------------------------------------------

subroutine cs_fuel_fp2st &
!=======================

 ( iscal  ,                                                        &
   rtpa   , rtp    , propce ,                                      &
   smbrs  , rovsdt )

!===============================================================================
! FONCTION :
! ----------

! ROUTINE PHYSIQUE PARTICULIERE : FLAMME CHARBON PULVERISE
!   TERMES SOURCES DE PRODUCTION ET DE DISSIPATION POUR
!   LA VARIANCE (BILANS EXPLICITE ET IMPLICITE)

!-------------------------------------------------------------------------------
!ARGU                             ARGUMENTS
!__________________.____._____.________________________________________________.
! name             !type!mode ! role                                           !
!__________________!____!_____!________________________________________________!
! rtp, rtpa        ! ra ! <-- ! calculated variables at cell centers           !
!  (ncelet, *)     !    !     !  (at current and previous time steps)          !
! propce(ncelet, *)! ra ! <-- ! physical properties at cell centers            !
! smbrs(ncelet)    ! tr ! --> ! second membre explicite                        !
! rovsdt(ncelet    ! tr ! --> ! partie diagonale implicite                     !
!__________________!____!_____!________________________________________________!

!     TYPE : E (ENTIER), R (REEL), A (ALPHANUMERIQUE), T (TABLEAU)
!            L (LOGIQUE)   .. ET TYPES COMPOSES (EX : TR TABLEAU REEL)
!     MODE : <-- donnee, --> resultat, <-> Donnee modifiee
!            --- tableau de travail
!===============================================================================

!===============================================================================
! Module files
!===============================================================================

use paramx
use numvar
use entsor
use optcal
use dimens, only: nvar
use cstphy
use cstnum
use parall
use period
use ppppar
use ppthch
use coincl
use cpincl
use ppincl
use ppcpfu
use cs_fuel_incl
use mesh
use field

!===============================================================================

implicit none

! Arguments

integer          iscal

double precision rtp(ncelet,nflown:nvar), rtpa(ncelet,nflown:nvar)
double precision propce(ncelet,*)
double precision smbrs(ncelet), rovsdt(ncelet)

! Local variables

integer           iel    , ifac   , ivar   ,ivar0 , ivarsc
integer           icla
integer           inc    , iccocg , nswrgp , imligp , iwarnp
integer           ipcte1 , ipcte2

double precision xk     , xe     , rhovst
double precision epsrgp , climgp , extrap
double precision aux
double precision gvap , t2mt1
!
integer           iok1,iok2
double precision, dimension(:), allocatable :: x1,f1f2
double precision, dimension(:), allocatable :: coefap , coefbp
double precision, allocatable, dimension(:,:) :: grad
double precision, dimension(:), pointer ::  crom
double precision, dimension(:), pointer :: visct
double precision, dimension(:), pointer :: cvara_k, cvara_ep, cvara_omg
double precision, dimension(:), pointer :: cvara_r11, cvara_r22, cvara_r33

!===============================================================================
! 1. Initialization
!===============================================================================

!===============================================================================
! Deallocation dynamic arrays

allocate(x1(1:ncelet) ,f1f2(1:ncelet),              STAT=iok1)
allocate(grad(ncelet,3), STAT=iok1)

if ( iok1 > 0 ) THEN
  write(nfecra,*) ' Memory allocation error inside: '
  write(nfecra,*) '     cs_fuel_fp2st               '
  call csexit(1)
endif
!===============================================================================

! --- La variance n'est pas associe a un scalaire
ivarsc = 0
ivar   = isca(iscal)

! --- Numero des grandeurs physiques
call field_get_val_s(icrom, crom)
call field_get_val_s(iprpfl(ivisct), visct)

if ( itytur.eq.2 .or. iturb.eq.50 ) then
  call field_get_val_prev_s(ivarfl(ik), cvara_k)
  call field_get_val_prev_s(ivarfl(iep), cvara_ep)
elseif ( itytur.eq.3 ) then
  call field_get_val_prev_s(ivarfl(ir11), cvara_r11)
  call field_get_val_prev_s(ivarfl(ir22), cvara_r22)
  call field_get_val_prev_s(ivarfl(ir33), cvara_r33)
  call field_get_val_prev_s(ivarfl(iep), cvara_ep)
elseif ( iturb.eq.60 ) then
  call field_get_val_prev_s(ivarfl(ik), cvara_k)
  call field_get_val_prev_s(ivarfl(iomg), cvara_omg)
endif

!===============================================================================
! 2. PRISE EN COMPTE DES TERMES SOURCES DE PRODUCTION PAR LES GRADIENTS
!    ET DE DISSIPATION
!===============================================================================
if ( itytur.eq.2 .or. iturb.eq.50 .or.             &
     itytur.eq.3 .or. iturb.eq.60      ) then
  inc = 1
  iccocg = 1
!
  nswrgp = nswrgr(isca(ifvap))
  imligp = imligr(isca(ifvap))
  iwarnp = iwarni(isca(ifvap))
  epsrgp = epsrgr(isca(ifvap))
  climgp = climgr(isca(ifvap))
  extrap = extrag(isca(ifvap))

! --> calcul de X1 et X2

  x1  ( : ) = 1.d0
  f1f2( : ) = 0.d0
  do icla = 1, nclafu
    do iel = 1, ncel
      f1f2(iel) = f1f2(iel) + rtp(iel,isca(ifvap))
      ! x1(iel)   = x1(iel)   - rtp(iel,isca(iyfol(icla)))
    enddo
  enddo

! --> calcul de F=YVAP/X1
  do iel = 1, ncel
    f1f2(iel) =f1f2(iel)/x1(iel)
  enddo

! --> Calcul du gradient de f1f2
!-----------------------------

  ! Allocate temporary arrays
  allocate(coefap(nfabor), coefbp(nfabor), STAT=iok1)

  if (iok1 > 0) then
    write(nfecra,*) ' Memory allocation error inside: '
    write(nfecra,*) '     cs_fuel_fp2st               '
    write(nfecra,*) ' with coefap and coefbp            '
    call csexit(1)
  endif

  do ifac = 1, nfabor
    ! Homogenous Neumann on the gradient
    coefap(ifac) = zero
    coefbp(ifac) = 1.d0
  enddo

! En periodique et parallele, echange avant calcul du gradient

  if (irangp.ge.0.or.iperio.eq.1) then
    call synsca(f1f2)
    !==========
  endif

!  IVAR0 = 0 (indique pour la periodicite de rotation que la variable
!     n'est pas la vitesse ni Rij)
  ivar0  = 0
  call grdcel &
  !==========
 ( ivar0  , imrgra , inc    , iccocg , nswrgp , imligp ,          &
   iwarnp , nfecra , epsrgp , climgp , extrap ,                   &
   f1f2   , coefap , coefbp ,                                     &
   grad   )

  do iel = 1, ncel
    if ( itytur.eq.2 .or. iturb.eq.50 ) then
      xk = cvara_k(iel)
      xe = cvara_ep(iel)
    elseif ( itytur.eq.3 ) then
      xk = 0.5d0*(cvara_r11(iel)+cvara_r22(iel)+cvara_r33(iel))
      xe = cvara_ep(iel)
    elseif ( iturb.eq.60 ) then
      xk = cvara_k(iel)
      xe = cmu*xk*cvara_omg(iel)
    endif

    rhovst = propce(iel,ipproc(irom1))*xe/(xk*rvarfl(iscal))*volume(iel)
    rovsdt(iel) = rovsdt(iel) + max(zero,rhovst)
    smbrs(iel) = smbrs(iel)                                                  &
                +2.d0*visct(iel)*volume(iel)/sigmas(iscal)                   &
                 *(grad(iel,1)**2.d0 + grad(iel,2)**2.d0 + grad(iel,3)**2.d0)&
                 *x1(iel) -rhovst*rtpa(iel,ivar)
  enddo

endif

!===============================================================================
! 3. PRISE EN COMPTE DES TERMES SOURCES RELATIF AUX ECHANGES INTERFACIAUX
!==============================================================================

call field_get_val_s(icrom, crom)
ipcte1 = ipproc(itemp1)
do icla=1,nclafu
!
  ipcte2 = ipproc(itemp2(icla))
!
  do iel = 1, ncel
!
    t2mt1  = propce(iel,ipcte2)-propce(iel,ipcte1)
    gvap = -propce(iel,ipproc(igmeva(icla)))*t2mt1*crom(iel)
!
    aux  = gvap*(1.d0-f1f2(iel))**2.d0
!
! ts implicite : pour l'instant on implicite de facon simple
!
    if ( abs(f1f2(iel)*(1.d0-f1f2(iel))) .GT. epsicp ) then
      rhovst = aux*rtpa(iel,ivar)/((f1f2(iel)*(1-f1f2(iel)))**2.d0)      &
                  *volume(iel)
    else
      rhovst = 0.d0
    endif
    rovsdt(iel) = rovsdt(iel) + max(zero,rhovst)
! ts explicite
    smbrs(iel) = smbrs(iel)+aux*volume(iel)-rhovst*rtpa(iel,ivar)
!
  enddo
enddo
!
!--------
! Formats
!--------

! Free memory
deallocate(x1,f1f2,grad,STAT=iok1)
deallocate(coefap,coefbp,STAT=iok2)

if (iok1 > 0 .or. iok2 > 0) then
  write(nfecra,*) ' Memory deallocation error inside: '
  write(nfecra,*) '     cs_fuel_fp2st                 '
  call csexit(1)
endif

!----
! End
!----

return
end subroutine
