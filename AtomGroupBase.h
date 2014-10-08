#ifndef ATOMGROUPBASE_H
#define ATOMGROUPBASE_H

#include <cassert>
#include <vector>

//
// Abstract base class for atom groups
//

class AtomGroupBase {

 protected:
  // Size of the group
  const int size;

  // Type of the group
  int type;

  // Global group list, constant
  const int numGroupList;

  // Group tables, change at every neighborlist build
  int numTable;
  int lenTable;
  int *table;

 public:

 AtomGroupBase(const int size, const int numGroupList) : 
  size(size), numGroupList(numGroupList) {
    assert(numGroupList > 0);
    numTable = 0;
    lenTable = 0;
    table = NULL;
  }

  void set_numTable(const int numTable) {
    assert(numTable <= lenTable);
    this->numTable = numTable;
  }

  void set_type(const int type) {
    this->type = type;
  }

  int get_type() {return type;}

  int* get_table() {return table;}
  int get_numTable() {return numTable;}
  int get_numGroupList() {return numGroupList;}
  virtual void resizeTable(const int new_numTable) = 0;
};

#endif // ATOMGROUPBASE_H