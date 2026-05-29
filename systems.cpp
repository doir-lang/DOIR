#include "systems.hpp"

namespace doir::system {
    bool& fixed_point_changed() {
		static bool changed = false;
		return changed;
	}
}