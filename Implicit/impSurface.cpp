/*
 * Copyright (C) 2001-2010  Terence M. Welsh
 *
 * This file is part of Implicit.
 *
 * Implicit is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * Implicit is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */


#include <Implicit/impSurface.h>
#include <rsMath/rsMath.h>
#include <string.h>


impSurface::impSurface(){
	index_offset = 0;
	vertex_offset = 0;
	vertices.resize(0);
	indices.resize(0);
}


impSurface::~impSurface(){
}


void impSurface::reset(){
	index_offset = 0;
	vertex_offset = 0;
}


void impSurface::addIndex(unsigned int index){
	// make more vertex data storage if necessary
	const size_t datasize(indices.size());
	if(index_offset == datasize)
		indices.resize(datasize + 1000);

	indices[index_offset++] = index;
}


void impSurface::addVertex(float* data){
	// make more vertex data storage if necessary
	const size_t datasize(vertices.size());
	if((vertex_offset + 6) >= datasize)
		vertices.resize(datasize + 1000);

	memcpy(&(vertices[vertex_offset]), data, 24);
	vertex_offset += 6;
}


void impSurface::draw(HSRenderer* renderer){
	if(index_offset == 0)
		return;

	renderer->drawIndexedMesh(&(vertices[0]), vertex_offset / 6, &(indices[0]), index_offset);
}
