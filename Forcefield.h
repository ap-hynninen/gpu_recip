#ifndef FORCEFIELD_H
#define FORCEFIELD_H

//
// Abstract base class for force fields
//
class Forcefield {

 public:
  
  virtual void print_energy_virial()=0;

};

#endif // FORCEFIELD_H