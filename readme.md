# DOIR

[![Language](https://img.shields.io/badge/language-C++%2074.4%25-blue?logo=c%2B%2B)](https://github.com/doir-lang/DOIR)
[![Language](https://img.shields.io/badge/language-C%2017.8%25-blue?logo=c)](https://github.com/doir-lang/DOIR)
[![Language](https://img.shields.io/badge/language-CMake%207.1%25-blue?logo=cmake)](https://github.com/doir-lang/DOIR)

DOIR is an experimental language framework exploring the use of an **Entity Component System (ECS)** as the core data structure for interpreter implementations. Currently, DOIR includes interpreters for:

- **Calculator**
- **JSON**
- **Lox** (from the [Crafting Interpreters](https://craftinginterpreters.com/) book)

All interpreter engines in this repository utilize an ECS architecture for representing program state, ASTs, and runtime entities.

---

## 🚀 What is an Entity Component System?

An Entity Component System (ECS) is a design pattern popular in game development and data-oriented programming. In ECS:

- **Entities** are unique identifiers.
- **Components** are plain data structs attached to entities.
- **Systems** operate on entities with specific component types.

This approach enables fast, cache-friendly access to data and flexible composition of behavior. Here, we apply ECS to language interpreter implementation—treating values, AST nodes, environments, and runtime objects as ECS entities and components.

---

## 🧩 Interpreters

### Calculator

A simple arithmetic expression evaluator supporting basic operations. Each node in the expression tree is represented as an ECS entity with components for value, operation, and children.

### JSON

A JSON parser and interpreter where objects, arrays, and values are ECS entities. The ECS enables traversal, mutation, and serialization via generic systems.

### Lox

A partial implementation of the Lox language from *Crafting Interpreters*, using ECS to represent variables, environments, functions, and runtime objects.

---

## ✨ Experimental Features

- **Unified ECS Core:** All interpreters share a common ECS backend, allowing code reuse and experimentation with interpreter structure.
- **Data-Oriented Design:** High-performance entity/component access and transformation.
- **Composable Systems:** Logic for parsing, evaluation, and runtime behaviors is encapsulated in ECS systems.
- **Simple Serialization:** Our [Serialization Code](https://github.com/doir-lang/DOIR/blob/ECS4Compilers/src/Lox/serialize.cpp) is under 100 lines long.

---

## 🛠️ Build Instructions

**Prerequisites:**
- C++20 or later compiler
- [CMake](https://cmake.org/)

**Build:**
```bash
git clone https://github.com/doir-lang/DOIR.git
cd DOIR
mkdir build && cd build
cmake ..
make
```

**Run:**
- See the `/tests` directory for usage.
- Executables for each interpreter will be available in `build/bin`.

---

## 📂 Directory Structure

```
/src         - Core ECS implementation and interpreter sources
/src/{Calculator, JSON, Lox}    - Example programs for calculator, json, and lox
/tests       - Unit and integration tests
/CMakeLists  - Build scripts
```

---

## 🧪 Status

This project is **experimental**. Expect breaking changes, incomplete features, and rapid iteration. Contributions, feedback, and ECS/PLT discussions are welcome!

---

## 📚 References

- [Crafting Interpreters](https://craftinginterpreters.com/)
- [Entity Component System Wikipedia](https://en.wikipedia.org/wiki/Entity_component_system)
- [Data-Oriented Design](https://www.dataorienteddesign.com/dodbook/)

---

## 📢 Citation

This project is academic work. **If you use DOIR in your research or publications, please cite:**

> Joshua Dahl and Frederick C. Harris. 2025. An Argument for the Practicality of Entity Component Systems as the Primary Data Structure for an Interpreter or Compiler. In Proceedings of the 2025 ACM SIGPLAN International Symposium on New Ideas, New Paradigms, and Reflections on Programming and Software (Onward! '25). Association for Computing Machinery, New York, NY, USA, 85–98. https://doi.org/10.1145/3759429.3762622

---

## 📝 License

[MIT](LICENSE)



